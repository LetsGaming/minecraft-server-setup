#!/bin/bash
# migrate.sh is an orchestrator over the modules in migrate-lib/: every module
# is loaded exactly once, loading one runs nothing, and a checkout without them
# says so instead of failing halfway.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"

ROOT="$(cd "$HERE/../.." && pwd)"
TMP=""
cleanup() { [[ -n "$TMP" && "$TMP" == */mcsetup-modules.* ]] && rm -rf "$TMP"; }
trap cleanup EXIT

test_every_module_is_sourced_exactly_once() {
  local f name n
  for f in "$ROOT"/migrate-lib/*.sh; do
    name="$(basename "$f")"
    n="$(grep -c "^source \"\$MIGRATE_LIB/$name\"\$" "$ROOT/migrate.sh")"
    assert_eq 1 "$n" "$name is sourced once"
  done
}

test_migrate_sh_sources_only_modules_that_exist() {
  local name
  while IFS= read -r name; do
    assert_exists "$ROOT/migrate-lib/$name" "migrate-lib/$name exists"
  done < <(sed -n 's|^source "\$MIGRATE_LIB/\(.*\)"$|\1|p' "$ROOT/migrate.sh")
}

test_every_file_parses() {
  local f
  bash -n "$ROOT/migrate.sh"; assert_rc 0 "$?" "migrate.sh parses"
  for f in "$ROOT"/migrate-lib/*.sh; do
    bash -n "$f"; assert_rc 0 "$?" "$(basename "$f") parses"
  done
}

test_loading_a_module_runs_nothing() {
  local f out rc
  for f in "$ROOT"/migrate-lib/*.sh; do
    out="$(bash -c "set -euo pipefail; source '$ROOT/migrate-lib/ui.sh'; source '$f'" 2>&1)"; rc=$?
    assert_rc 0 "$rc" "$(basename "$f") loads cleanly"
    assert_eq "" "$out" "$(basename "$f") prints nothing when loaded"
  done
}

test_help_works_from_a_copy() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-modules.XXXXXX")"
  cp "$ROOT/migrate.sh" "$TMP/"; cp -r "$ROOT/migrate-lib" "$TMP/"
  local out rc
  out="$(bash "$TMP/migrate.sh" --help 2>&1)"; rc=$?
  assert_rc 0 "$rc" "--help succeeds"
  assert_contains "$out" "Usage:" "and prints the usage"
  cleanup
}

test_a_checkout_without_the_modules_says_so() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-modules.XXXXXX")"
  cp "$ROOT/migrate.sh" "$TMP/"
  local out rc
  out="$(bash "$TMP/migrate.sh" --help 2>&1)"; rc=$?
  assert_rc 1 "$rc" "it stops"
  assert_contains "$out" "migrate-lib/ not found" "and names the missing folder"
  cleanup
}

# create_backup in a scratch tree, with gzip (no zstd needed) and an optional
# fake tar on PATH.
run_create_backup() { # scripts-dir [bin-dir]
  bash -c "
    set -u
    export PATH='${2:-/nonexistent}:$PATH'
    source '$ROOT/migrate-lib/ui.sh'; source '$ROOT/migrate-lib/backup.sh'
    TARGET_SCRIPTS_DIR='$1'; USE_ZSTD=false; DRY_RUN=false; MIGRATE_KEEP_ARCHIVES=5
    create_backup && prune_old_migration_archives
  " 2>&1
}

test_the_migration_archive_is_published_only_after_it_verified() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-modules.XXXXXX")"
  mkdir -p "$TMP/scripts/common"
  echo 'A="b"' > "$TMP/scripts/common/variables.txt"
  local out
  out="$(run_create_backup "$TMP/scripts")"
  assert_eq 1 "$(find "$TMP" -maxdepth 1 -name 'scripts_backup_*.tar.gz' | wc -l | tr -d '[:space:]')" "one archive written"
  assert_eq "" "$(find "$TMP" -maxdepth 1 -name '.*.part')" "no partial file left"
  assert_contains "$out" "Archive size" "reports the size"
}

test_a_tar_that_dies_midway_leaves_no_migration_archive() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-modules.XXXXXX")"
  mkdir -p "$TMP/scripts/common" "$TMP/bin"
  echo 'A="b"' > "$TMP/scripts/common/variables.txt"
  echo stale > "$TMP/scripts_backup_20200101_000000.tar.gz"
  cat > "$TMP/bin/tar" <<'SH'
#!/bin/bash
for a in "$@"; do [[ "$a" == -c* ]] && { echo "tar: disk full" >&2; exit 2; }; done
exec "$(PATH="${PATH#*:}" command -v tar)" "$@"
SH
  chmod +x "$TMP/bin/tar"
  local out rc=0
  out="$(run_create_backup "$TMP/scripts" "$TMP/bin")" || rc=$?
  assert_nonzero "$rc" "create_backup fails"
  assert_contains "$out" "failed" "says so"
  assert_eq "" "$(find "$TMP" -maxdepth 1 -name '.*.part')" "no partial file left"
  assert_eq 1 "$(find "$TMP" -maxdepth 1 -name 'scripts_backup_*.tar.gz' | wc -l | tr -d '[:space:]')" "only the old archive remains; nothing truncated counts as new"
}

run_tests
