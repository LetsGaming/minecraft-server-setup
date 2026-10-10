#!/bin/bash
# Tests for backup/automation/cleanup_backups.sh against scratch trees.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

CLEANUP="backup/automation/cleanup_backups.sh"
setup() { make_fixture; trap cleanup_fixture EXIT; }

set_var() { echo "$1=\"$2\"" >> "$T/scripts/common/variables.txt"; }

# mk_backup <relative-dir> <name> <day>: a 100 byte archive-named file whose
# mtime is 2026-01-<day>, so a larger day is newer.
mk_backup() {
  local dir="$T/backups/$1" name="$2" day="$3"
  mkdir -p "$dir"
  head -c 100 /dev/zero > "$dir/$name"
  touch -d "2026-01-$(printf '%02d' "$day") 00:00:00" "$dir/$name"
}

old_jar() { # name day: a jar well past the one-day grace period
  mkdir -p "$T/backups/jars"
  echo jar > "$T/backups/jars/$1"
  touch -d "2026-01-01 00:00:00" "$T/backups/jars/$1"
}

# ── storage limit: eviction order ────────────────────────────────────────────

test_storage_limit_evicts_cheap_tiers_first_and_monthly_last() {
  setup
  set_var MAX_STORAGE_GB 1
  mk_backup archives/monthly minecraft_backup_m1.tar.zst 1
  mk_backup hourly minecraft_backup_h1.tar.zst 5
  mk_backup hourly minecraft_backup_h2.tar.zst 6
  mk_backup archives/daily minecraft_backup_d1.tar.zst 7
  mk_backup archives/weekly minecraft_backup_w1.tar.zst 8
  mk_backup archives/update minecraft_backup_u1.tar.zst 9
  export DU_SHIM_BYTES=$((1073741824 + 350))
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_exists "$T/backups/archives/monthly/minecraft_backup_m1.tar.zst" "the oldest file overall, a monthly, survives"
  assert_exists "$T/backups/archives/update/minecraft_backup_u1.tar.zst" "update archive kept"
  assert_missing "$T/backups/hourly/minecraft_backup_h1.tar.zst" "oldest hourly evicted first"
  assert_missing "$T/backups/hourly/minecraft_backup_h2.tar.zst" "then the next hourly"
  assert_missing "$T/backups/archives/daily/minecraft_backup_d1.tar.zst" "then daily"
  assert_missing "$T/backups/archives/weekly/minecraft_backup_w1.tar.zst" "then weekly"
}

test_storage_limit_reaches_monthly_only_when_nothing_else_is_left() {
  setup
  set_var MAX_STORAGE_GB 1
  mk_backup archives/monthly minecraft_backup_m1.tar.zst 1
  mk_backup archives/monthly minecraft_backup_m2.tar.zst 2
  mk_backup hourly minecraft_backup_h1.tar.zst 9
  export DU_SHIM_BYTES=$((1073741824 + 150))
  run_script "$CLEANUP"
  assert_missing "$T/backups/hourly/minecraft_backup_h1.tar.zst" "hourly goes first even though it is the newest file"
  assert_missing "$T/backups/archives/monthly/minecraft_backup_m1.tar.zst" "then the oldest monthly"
  assert_exists "$T/backups/archives/monthly/minecraft_backup_m2.tar.zst" "stops once under the limit"
}

test_storage_limit_untouched_when_under() {
  setup
  set_var MAX_STORAGE_GB 1
  mk_backup hourly minecraft_backup_h1.tar.zst 5
  export DU_SHIM_BYTES=1000
  run_script "$CLEANUP"
  assert_exists "$T/backups/hourly/minecraft_backup_h1.tar.zst" "nothing evicted"
}

# ── update archive count cap ─────────────────────────────────────────────────

test_update_archives_are_capped_by_count_keeping_the_newest() {
  setup
  set_var MAX_UPDATE_BACKUPS 2
  for d in 1 2 3 4; do mk_backup archives/update "minecraft_backup_u$d.tar.zst" "$d"; done
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_exists "$T/backups/archives/update/minecraft_backup_u4.tar.zst" "newest kept"
  assert_exists "$T/backups/archives/update/minecraft_backup_u3.tar.zst" "second newest kept"
  assert_missing "$T/backups/archives/update/minecraft_backup_u2.tar.zst" "older pruned"
  assert_missing "$T/backups/archives/update/minecraft_backup_u1.tar.zst" "oldest pruned"
}

test_update_cap_defaults_to_five() {
  setup
  for d in 1 2 3 4 5 6 7; do mk_backup archives/update "minecraft_backup_u$d.tar.zst" "$d"; done
  run_script "$CLEANUP"
  assert_eq "5" "$(ls "$T/backups/archives/update" | wc -l | tr -d '[:space:]')" "five kept by default"
}

# ── orphan jars ──────────────────────────────────────────────────────────────

test_orphan_jars_are_pruned_and_referenced_jars_kept() {
  setup
  old_jar kept.jar
  old_jar orphan.jar
  mkdir -p "$T/backups/jars"
  echo fresh > "$T/backups/jars/fresh.jar"
  mkdir -p "$T/backups/archives/daily"
  node "$HERE/lib/mk_symlink_archive.js" "$T/backups/archives/daily/minecraft_backup_d1.tar.zst" \
    "kept.jar=../../../jars/kept.jar"
  touch -d "2026-01-02 00:00:00" "$T/backups/archives/daily/minecraft_backup_d1.tar.zst"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_exists "$T/backups/jars/kept.jar" "a jar an archive still links to is kept"
  assert_missing "$T/backups/jars/orphan.jar" "an unreferenced old jar is removed"
  assert_exists "$T/backups/jars/fresh.jar" "a jar younger than a day is kept (a backup may be mid-flight)"
}

test_jar_pruning_is_skipped_when_an_archive_cannot_be_listed() {
  setup
  old_jar orphan.jar
  mkdir -p "$T/backups/archives/daily"
  echo "not an archive" > "$T/backups/archives/daily/minecraft_backup_d1.tar.zst"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup still succeeds"
  assert_contains "$OUT" "skipping jar pruning" "says why"
  assert_exists "$T/backups/jars/orphan.jar" "no jar is deleted on doubt"
}

# ── resilience ───────────────────────────────────────────────────────────────

test_a_failed_removal_does_not_abort_the_run() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  mk_backup hourly minecraft_backup_h1.tar.zst 1
  mk_backup hourly minecraft_backup_h2.tar.zst 2
  mk_backup hourly minecraft_backup_h3.tar.zst 3
  mk_backup archives/update minecraft_backup_u1.tar.zst 1
  mk_backup archives/update minecraft_backup_u2.tar.zst 2
  set_var MAX_UPDATE_BACKUPS 1
  # rm shim: refuse to delete h1, delete anything else.
  cat > "$T/bin/rm" <<'RMSHIM'
#!/bin/bash
for a in "$@"; do
  if [[ "$a" == *minecraft_backup_h1.tar.zst ]]; then echo "rm: cannot remove '$a'" >&2; exit 1; fi
done
exec "$REAL_RM" "$@"
RMSHIM
  chmod +x "$T/bin/rm"
  export REAL_RM
  REAL_RM="$(PATH="${PATH#"$T/bin:"}" command -v rm)"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "one undeletable file does not fail the run"
  assert_contains "$OUT" "could not delete" "the failure is reported"
  assert_missing "$T/backups/hourly/minecraft_backup_h2.tar.zst" "other files are still processed"
  assert_missing "$T/backups/archives/update/minecraft_backup_u1.tar.zst" "later policies still run"
}

run_tests
