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

run_tests
