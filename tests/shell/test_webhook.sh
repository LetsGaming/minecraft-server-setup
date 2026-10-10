#!/bin/bash
# Tests for common/webhook.sh.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

URL='https://discord.com/api/webhooks/123/SECRET-TOKEN'
setup() {
  make_fixture; trap cleanup_fixture EXIT
  echo "WEBHOOK_URL=\"$URL\"" >> "$T/scripts/common/variables.txt"
}

test_notify_keeps_the_url_off_the_command_line() {
  setup
  ( cd "$T/scripts" && source common/server_control.sh && notify_success backup_complete "done" && wait_for_notifications ) > /dev/null 2>&1
  assert_logged "curl " "curl was invoked"
  assert_not_logged "SECRET-TOKEN" "the token never appears in curl's arguments"
  assert_not_logged "$URL" "nor the URL"
  assert_contains "$(cat "$SHIM_STATE/curl_stdin")" "$URL" "the URL arrives as a config line on stdin"
  assert_contains "$(cat "$SHIM_STATE/curl_stdin")" 'url = "' "in curl config syntax"
}

test_notify_bounds_the_request_and_fails_on_http_errors() {
  setup
  ( cd "$T/scripts" && source common/server_control.sh && notify_error backup_failed "oops" && wait_for_notifications ) > /dev/null 2>&1
  assert_logged "--max-time 10" "request time is bounded"
  assert_logged "--connect-timeout" "connect time is bounded"
  assert_logged " -sS -f " "HTTP errors make curl fail"
}

test_url_with_quote_or_backslash_cannot_break_the_config_line() {
  setup
  echo 'WEBHOOK_URL="https://x.example/a\"b\\c"' >> "$T/scripts/common/variables.txt"
  ( cd "$T/scripts" && source common/server_control.sh && notify_success e "m" && wait_for_notifications ) > /dev/null 2>&1
  assert_file_content "$SHIM_STATE/curl_stdin" 'url = "https://x.example/a\"b\\c"' "quote and backslash are escaped for curl's config parser"
}

test_wait_for_notifications_waits_for_the_background_request() {
  setup
  export CURL_SHIM_GATE=1
  (
    cd "$T/scripts" && source common/server_control.sh
    notify_success backup_complete "done"
    touch "$SHIM_STATE/curl_go"
    wait_for_notifications
    [[ -e "$SHIM_STATE/curl_done" ]]
  ) > /dev/null 2>&1
  assert_rc 0 "$?" "the request has finished by the time the wait returns"
}

test_no_webhook_means_no_curl() {
  setup
  echo 'WEBHOOK_URL=""' >> "$T/scripts/common/variables.txt"
  ( cd "$T/scripts" && source common/server_control.sh && notify_success e "m" && wait_for_notifications ) > /dev/null 2>&1
  assert_not_logged "curl " "nothing is sent without a URL"
}

run_tests
