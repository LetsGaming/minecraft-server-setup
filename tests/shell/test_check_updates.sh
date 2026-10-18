#!/bin/bash
# Tests for misc/check_updates.sh (CurseForge update check) with the curl shim.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() {
  make_fixture; trap cleanup_fixture EXIT
  mkdir -p "$T/scripts/misc"
  cp "$SCRIPTS_SRC/misc/check_updates.sh" "$T/scripts/misc/"
  echo 'API_KEY="secret-key-123"' > "$T/scripts/common/curseforge.txt"
  echo '{"modpack":{"111":222},"mods":{"333":444}}' > "$T/scripts/common/downloaded_versions.json"
}

test_a_failed_fetch_is_an_error_not_an_update() {
  setup
  run_script misc/check_updates.sh
  assert_rc 1 "$RC" "exits non-zero when nothing could be fetched"
  assert_contains "$OUT" "could not check for an update" "says the check failed"
  assert_not_contains "$OUT" "update available" "never claims an update"
  assert_not_contains "$OUT" "is up to date" "never claims current either"
}

test_the_api_key_is_not_in_the_curl_arguments() {
  setup
  run_script misc/check_updates.sh
  assert_logged "curl" "curl was called"
  assert_not_logged "secret-key-123" "the key is not in the argument list"
  assert_contains "$(cat "$SHIM_STATE/curl_stdin" 2>/dev/null)" "x-api-key: secret-key-123" "the key is passed on stdin"
}

run_tests
