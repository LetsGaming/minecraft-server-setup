#!/bin/bash
# Characterization of rollback.sh (current behaviour, defects included).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() { make_fixture; trap cleanup_fixture EXIT; }
ROLLBACK="rollback.sh"
UPDATE_DIR_REL="archives/update"

# rollback.sh runs under `set -u` and sources common/webhook.sh, which reads
# $_WEBHOOK_LOADED before it is ever assigned, so every invocation dies at
# source time. The destructive code paths further down are therefore
# unreachable today.
test_rollback_dies_on_unbound_variable() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_2026-01-01_00-00-00.tar.zst" before-update
  run_script "$ROLLBACK" --y
  assert_rc 1 "$RC" "rollback exits 1"
  assert_contains "$OUT" "_WEBHOOK_LOADED: unbound variable" "fails while sourcing webhook.sh"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

test_list_flag_dies_on_unbound_variable() {
  setup
  run_script "$ROLLBACK" --list
  assert_rc 1 "$RC" "--list exits 1 for the same reason"
}

run_tests
