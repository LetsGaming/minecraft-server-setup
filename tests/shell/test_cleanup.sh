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
  # The helper writes gzip, so the archive is named .tar.gz when the real zstd
  # would otherwise be asked to read it.
  local ext=zst; real_tools && ext=gz
  node "$HERE/lib/mk_symlink_archive.js" "$T/backups/archives/daily/minecraft_backup_d1.tar.$ext" \
    "kept.jar=../../../jars/kept.jar"
  touch -d "2026-01-02 00:00:00" "$T/backups/archives/daily/minecraft_backup_d1.tar.$ext"
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

test_a_count_cap_of_zero_keeps_everything() {
  # S-030: MAX_HOURLY_BACKUPS=0 deleted every hourly backup, and a 0 for an
  # archive tier stopped the cleanup with an error.
  setup
  set_var MAX_HOURLY_BACKUPS 0
  set_var MAX_DAILY_BACKUPS 0
  mk_backup hourly minecraft_backup_h1.tar.zst 5
  mk_backup hourly minecraft_backup_h2.tar.zst 6
  mk_backup archives/daily minecraft_backup_d1.tar.zst 7
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_exists "$T/backups/hourly/minecraft_backup_h1.tar.zst" "hourly backups are kept"
  assert_exists "$T/backups/hourly/minecraft_backup_h2.tar.zst" "all of them"
  assert_exists "$T/backups/archives/daily/minecraft_backup_d1.tar.zst" "and the daily one"
}

# ── retention covers every archive type ──────────────────────────────────────

test_general_and_custom_archives_are_evicted_before_monthly_when_space_runs_out() {
  setup
  set_var MAX_STORAGE_GB 1
  mk_backup archives/monthly minecraft_backup_m1.tar.zst 1
  mk_backup archives/monthly minecraft_backup_m2.tar.zst 2
  mk_backup archives/general minecraft_backup_g1.tar.zst 3
  mk_backup archives/general minecraft_backup_g2.tar.zst 4
  mk_backup archives/before-event minecraft_backup_c1.tar.zst 5
  export DU_SHIM_BYTES=$((1073741824 + 250))
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_missing "$T/backups/archives/general/minecraft_backup_g1.tar.zst" "the oldest general archive goes first"
  assert_missing "$T/backups/archives/general/minecraft_backup_g2.tar.zst" "then the next one"
  assert_missing "$T/backups/archives/before-event/minecraft_backup_c1.tar.zst" "then the custom type"
  assert_exists "$T/backups/archives/monthly/minecraft_backup_m1.tar.zst" "monthly is untouched while others remain"
  assert_exists "$T/backups/archives/monthly/minecraft_backup_m2.tar.zst" "both monthlies"
}

test_custom_archives_follow_the_custom_count_cap() {
  setup
  set_var MAX_CUSTOM_BACKUPS 1
  mk_backup archives/general minecraft_backup_g1.tar.zst 1
  mk_backup archives/general minecraft_backup_g2.tar.zst 2
  mk_backup archives/pre-event minecraft_backup_c1.tar.zst 3
  mk_backup archives/pre-event minecraft_backup_c2.tar.zst 4
  run_script "$CLEANUP"
  assert_missing "$T/backups/archives/general/minecraft_backup_g1.tar.zst" "the older general archive is pruned"
  assert_exists "$T/backups/archives/general/minecraft_backup_g2.tar.zst" "the newest is kept"
  assert_missing "$T/backups/archives/pre-event/minecraft_backup_c1.tar.zst" "the older custom archive is pruned"
  assert_exists "$T/backups/archives/pre-event/minecraft_backup_c2.tar.zst" "the newest is kept"
}

test_custom_archives_are_kept_by_default() {
  setup
  mk_backup archives/general minecraft_backup_g1.tar.zst 1
  mk_backup archives/general minecraft_backup_g2.tar.zst 2
  run_script "$CLEANUP"
  assert_exists "$T/backups/archives/general/minecraft_backup_g1.tar.zst" "no count limit unless MAX_CUSTOM_BACKUPS is set"
  assert_exists "$T/backups/archives/general/minecraft_backup_g2.tar.zst" "both kept"
}

# ── the file name decides the order, and the last valid archive stays ────────

test_the_timestamp_in_the_name_decides_which_archive_is_newest() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  local old="minecraft_backup_2026-01-01_00-00-00.tar.zst" new="minecraft_backup_2026-02-01_00-00-00.tar.zst"
  mk_backup hourly "$old" 20
  mk_backup hourly "$new" 2
  run_script "$CLEANUP"
  assert_exists "$T/backups/hourly/$new" "the later name is kept although its mtime is older"
  assert_missing "$T/backups/hourly/$old" "the earlier name is pruned although its mtime is newer"
}

test_the_newest_valid_archive_of_a_tier_is_never_evicted() {
  setup
  set_var MAX_STORAGE_GB 1
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" only-good
  export DU_SHIM_BYTES=$((1073741824 + 5000))
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_exists "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" "the only valid archive stays"
  assert_contains "$OUT" "still above" "the overflow is reported instead"
}

test_an_overflow_that_eviction_cannot_fix_sends_storage_warning() {
  setup
  set_var MAX_STORAGE_GB 1
  set_var WEBHOOK_URL "https://hooks.example/x"
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" only-good
  export DU_SHIM_BYTES=$((1073741824 + 5000))
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_contains "$(cat "$SHIM_STATE/curl_stdin")" "hooks.example" "a notification was sent"
  assert_logged "storage_warning" "of the storage_warning kind"
}

test_a_run_within_the_limit_sends_no_storage_warning() {
  setup
  set_var MAX_STORAGE_GB 1
  set_var WEBHOOK_URL "https://hooks.example/x"
  export DU_SHIM_BYTES=100
  run_script "$CLEANUP"
  assert_not_logged "storage_warning" "nothing to warn about"
}

test_a_corrupt_newest_archive_does_not_shield_older_ones_from_being_the_kept_one() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" good
  mkdir -p "$T/backups/hourly"
  echo "broken" > "$T/backups/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst"
  run_script "$CLEANUP"
  assert_exists "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" "the older but valid archive survives the count cap"
}

# ── the size measure and the operation lock ──────────────────────────────────

test_the_size_measure_leaves_out_staging_sidecars_and_the_jars_folder() {
  setup
  set_var MAX_STORAGE_GB 1
  run_script "$CLEANUP"
  assert_logged "du -sb --exclude=tmp_backup --exclude=jars --exclude=.stage --exclude=.meta $T/backups" "du skips tmp_backup, jars, .stage and .meta"
}

# ── cheap cleanup: jars, bad config, pre-restore expiry ──────────────────────

test_an_empty_jars_folder_is_removed_without_decompressing_anything() {
  setup
  mkdir -p "$T/backups/jars"
  make_archive "$T/backups/archives/daily/minecraft_backup_2026-01-01_00-00-00.tar.zst" d
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_missing "$T/backups/jars" "the empty legacy folder is gone"
  assert_not_logged "zstd -dc" "no archive was decompressed for it"
}

test_jars_too_young_to_prune_do_not_trigger_an_archive_scan() {
  setup
  mkdir -p "$T/backups/jars"
  echo fresh > "$T/backups/jars/fresh.jar"
  make_archive "$T/backups/archives/daily/minecraft_backup_2026-01-01_00-00-00.tar.zst" d
  run_script "$CLEANUP"
  assert_not_logged "zstd -dc" "no archive listing when no jar is old enough"
  assert_exists "$T/backups/jars/fresh.jar" "the jar stays"
}

test_the_orphan_jar_scan_runs_at_most_once_a_day() {
  setup
  old_jar orphan.jar
  make_archive "$T/backups/archives/daily/minecraft_backup_2026-01-01_00-00-00.tar.zst" d
  run_script "$CLEANUP"
  assert_missing "$T/backups/jars/orphan.jar" "the orphan is removed on the first run"
  old_jar orphan2.jar
  : > "$SHIM_LOG"
  run_script "$CLEANUP"
  assert_contains "$OUT" "already checked today" "the second run skips the scan"
  assert_not_logged "zstd -dc" "and decompresses nothing"
  assert_exists "$T/backups/jars/orphan2.jar" "the new orphan waits for tomorrow"
}

test_a_bad_tier_value_skips_only_that_tier() {
  setup
  set_var MAX_DAILY_BACKUPS "lots"
  set_var MAX_WEEKLY_BACKUPS 1
  mk_backup archives/daily minecraft_backup_d1.tar.zst 1
  mk_backup archives/weekly minecraft_backup_w1.tar.zst 1
  mk_backup archives/weekly minecraft_backup_w2.tar.zst 2
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup still succeeds"
  assert_contains "$OUT" "MAX_DAILY_BACKUPS" "the bad value is reported"
  assert_exists "$T/backups/archives/daily/minecraft_backup_d1.tar.zst" "the daily tier is left alone"
  assert_missing "$T/backups/archives/weekly/minecraft_backup_w1.tar.zst" "the weekly cap still applies"
}

test_a_decimal_storage_limit_is_reported_and_skipped() {
  setup
  set_var MAX_STORAGE_GB 1.5
  mk_backup hourly minecraft_backup_h1.tar.zst 1
  export DU_SHIM_BYTES=$((1073741824 * 3))
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "no arithmetic abort"
  assert_contains "$OUT" "MAX_STORAGE_GB" "the bad value is reported"
  assert_contains "$OUT" "Backup cleanup complete." "the run finishes"
  assert_exists "$T/backups/hourly/minecraft_backup_h1.tar.zst" "nothing evicted on a bad limit"
}

test_an_old_pre_restore_copy_is_removed_after_the_keep_period() {
  setup
  mkdir -p "$T/server.pre-restore/world"
  touch -d "8 days ago" "$T/server.pre-restore"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_missing "$T/server.pre-restore" "the copy older than 7 days is gone"
}

test_a_recent_pre_restore_copy_is_kept() {
  setup
  mkdir -p "$T/server.pre-restore/world"
  touch -d "2 days ago" "$T/server.pre-restore"
  run_script "$CLEANUP"
  assert_exists "$T/server.pre-restore" "a 2 day old copy stays"
  set_var RESTORE_KEEP_OLD_DAYS 1
  run_script "$CLEANUP"
  assert_missing "$T/server.pre-restore" "unless RESTORE_KEEP_OLD_DAYS says otherwise"
}

# ── sidecars decide validity; legacy archives are tested once ───────────────

test_a_legacy_archive_without_sidecar_is_tested_once_and_gets_one() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" a
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst" b
  rm -rf "$T/backups/.meta"   # archives from before sidecars existed
  touch -d "2026-01-01 00:05:00" "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst"
  touch -d "2026-01-02 00:05:00" "$T/backups/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_logged "zstd -t" "the newest legacy archive is tested"
  local side="$T/backups/.meta/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst.sha256"
  assert_exists "$side" "and gets a sidecar"
  assert_file_content "$side" "$(sha256sum "$T/backups/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst" | cut -d' ' -f1)  minecraft_backup_2026-01-02_00-00-00.tar.zst" "recording its real hash"
  : > "$SHIM_LOG"
  run_script "$CLEANUP"
  assert_not_logged "zstd -t" "the next run trusts the sidecar"
}

test_a_legacy_archive_whose_mtime_does_not_back_its_name_gets_no_sidecar() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" a
  make_archive "$T/backups/hourly/minecraft_backup_2026-12-31_00-00-00.tar.zst" renamed
  rm -rf "$T/backups/.meta"
  touch -d "2025-06-01 00:00:00" "$T/backups/hourly/minecraft_backup_2026-12-31_00-00-00.tar.zst"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "cleanup succeeds"
  assert_contains "$OUT" "No sidecar written" "says why"
  assert_missing "$T/backups/.meta/hourly/minecraft_backup_2026-12-31_00-00-00.tar.zst.sha256" "no trust record for a name the mtime does not back"
  assert_exists "$T/backups/hourly/minecraft_backup_2026-12-31_00-00-00.tar.zst" "it is still the protected newest valid archive of the tier"
}

test_a_sidecar_vouches_without_decompression() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  mk_backup hourly minecraft_backup_2026-01-01_00-00-00.tar.zst 1
  mk_backup hourly minecraft_backup_2026-01-02_00-00-00.tar.zst 2
  mkdir -p "$T/backups/.meta/hourly"
  echo "abc  minecraft_backup_2026-01-02_00-00-00.tar.zst" > "$T/backups/.meta/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst.sha256"
  run_script "$CLEANUP"
  assert_not_logged "zstd -t" "no integrity test for an archive with a sidecar"
  assert_missing "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" "the older one is pruned"
  assert_missing "$T/backups/.meta/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst.sha256" "and would take its sidecar with it"
}

# ── --make-room and hardlink-aware eviction ─────────────────────────────────

test_make_room_evicts_in_tier_order_until_enough_is_free() {
  setup
  mk_backup archives/monthly minecraft_backup_m1.tar.zst 1
  mk_backup hourly minecraft_backup_2026-01-05_00-00-00.tar.zst 5
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-06_00-00-00.tar.zst" h2
  mk_backup archives/daily minecraft_backup_2026-01-07_00-00-00.tar.zst 7
  make_archive "$T/backups/archives/daily/minecraft_backup_2026-01-08_00-00-00.tar.zst" d2
  export DF_SHIM_AVAIL=1000
  run_script "$CLEANUP" --make-room 1150
  assert_rc 0 "$RC" "enough was freed"
  assert_missing "$T/backups/hourly/minecraft_backup_2026-01-05_00-00-00.tar.zst" "oldest hourly first"
  assert_exists "$T/backups/hourly/minecraft_backup_2026-01-06_00-00-00.tar.zst" "the newest valid hourly is protected"
  assert_missing "$T/backups/archives/daily/minecraft_backup_2026-01-07_00-00-00.tar.zst" "then the oldest daily"
  assert_exists "$T/backups/archives/daily/minecraft_backup_2026-01-08_00-00-00.tar.zst" "stops once the target is met"
  assert_exists "$T/backups/archives/monthly/minecraft_backup_m1.tar.zst" "monthly untouched"
}

test_make_room_exits_73_when_it_cannot_free_enough() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-05_00-00-00.tar.zst" only
  export DF_SHIM_AVAIL=1000
  run_script "$CLEANUP" --make-room 5000
  assert_rc 73 "$RC" "exit 73"
  assert_contains "$OUT" "Could not free enough space" "says so"
  assert_exists "$T/backups/hourly/minecraft_backup_2026-01-05_00-00-00.tar.zst" "the only valid archive of the tier stays"
}

test_eviction_does_not_count_bytes_a_hardlinked_archive_shares() {
  setup
  mk_backup hourly minecraft_backup_2026-01-01_00-00-00.tar.zst 1
  mk_backup hourly minecraft_backup_2026-01-02_00-00-00.tar.zst 2
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-03_00-00-00.tar.zst" h3
  mkdir -p "$T/backups/archives/daily"
  if ! ln "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" "$T/backups/archives/daily/minecraft_backup_2026-01-01_00-00-00.tar.zst" 2>/dev/null; then
    skip "hardlink accounting" "this host cannot create hard links here"
    return
  fi
  export DF_SHIM_AVAIL=0
  run_script "$CLEANUP" --make-room 100
  assert_rc 0 "$RC" "the target is met"
  assert_missing "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" "the linked file is evicted"
  assert_missing "$T/backups/hourly/minecraft_backup_2026-01-02_00-00-00.tar.zst" "but counted as zero, so the next one goes too"
  assert_exists "$T/backups/hourly/minecraft_backup_2026-01-03_00-00-00.tar.zst" "the newest valid one stays"
}

test_cleanup_waits_for_a_running_operation() {
  setup
  set_var MAX_HOURLY_BACKUPS 1
  mk_backup hourly minecraft_backup_h1.tar.zst 1
  mk_backup hourly minecraft_backup_h2.tar.zst 2
  export FLOCK_SHIM_BUSY=1 INSTANCE_LOCK_DIR="$T/locks"
  run_script "$CLEANUP"
  assert_rc 0 "$RC" "a busy lock is a skip, not a failure"
  assert_contains "$OUT" "skipping backup cleanup" "says it skipped"
  assert_exists "$T/backups/hourly/minecraft_backup_h1.tar.zst" "nothing was deleted"
}

run_tests
