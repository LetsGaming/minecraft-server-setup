#!/bin/bash
# Tests for the lifecycle events src/vanilla/start.sh writes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

START_SRC="$(cd "$HERE/../../src/vanilla" && pwd)/start.sh"

# An instance dir holding start.sh and a variables.txt whose "java" is the
# given command, so the loop runs without a real JVM.
make_instance() { # java-command
  make_fixture; trap cleanup_fixture EXIT
  INST="$T/instances/testinst"
  mkdir -p "$INST"
  cp "$START_SRC" "$INST/start.sh"
  cat > "$INST/variables.txt" <<VARS
JAVA="$1"
JAVA_ARGS=""
ADDITIONAL_ARGS=""
USE_FABRIC="false"
RESTART="true"
WAIT_FOR_USER_INPUT="false"
VARS
  EVENTS="$INST/logs/lifecycle.ndjson"
}

count_type() { grep -c "\"type\":\"$1\"" "$EVENTS" 2> /dev/null || true; }

test_crash_loop_emits_start_exit_restart_and_gave_up() {
  make_instance "false"
  bash "$INST/start.sh" > /dev/null 2>&1
  assert_rc 1 "$?" "start.sh still exits 1 when it gives up"
  assert_exists "$EVENTS" "the events file is created under logs/"
  assert_eq 5 "$(count_type jvm_start)" "one jvm_start per attempt"
  assert_eq 5 "$(count_type jvm_exit)" "one jvm_exit per attempt"
  assert_eq 4 "$(count_type restart_scheduled)" "a restart is scheduled between attempts, not after giving up"
  assert_eq 1 "$(count_type crash_loop_gave_up)" "give-up is reported once"
  assert_contains "$(grep gave_up "$EVENTS")" '"rapid_crashes":5' "give-up carries the crash count"
  assert_contains "$(grep gave_up "$EVENTS")" '"exit_code":1' "and the last exit code"
}

test_every_line_is_valid_json() {
  make_instance "false"
  bash "$INST/start.sh" > /dev/null 2>&1
  if command -v node > /dev/null 2>&1; then
    local bad
    bad="$(node -e '
      const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
      let bad = 0;
      for (const l of lines) { try { const o = JSON.parse(l); if (typeof o.ts !== "number" || !o.type) bad++; } catch { bad++; } }
      console.log(bad);' "$EVENTS")"
    assert_eq 0 "$bad" "each line parses and carries ts and type"
  else
    skip "json validity" "node not found"
  fi
}

test_clean_stop_without_restart_emits_no_give_up() {
  make_instance "true"
  sed -i 's/^RESTART=.*/RESTART="false"/' "$INST/variables.txt"
  bash "$INST/start.sh" > /dev/null 2>&1
  assert_rc 0 "$?" "a clean exit with RESTART=false exits 0"
  assert_eq 1 "$(count_type jvm_start)" "one start"
  assert_eq 0 "$(count_type crash_loop_gave_up)" "no give-up"
}

test_crash_report_name_is_a_reference_not_content() {
  make_instance "false"
  mkdir -p "$INST/crash-reports"
  : > "$INST/crash-reports/crash-2026-10-12_10.00.00-server.txt"
  bash "$INST/start.sh" > /dev/null 2>&1
  assert_contains "$(grep gave_up "$EVENTS")" 'crash-2026-10-12_10.00.00-server.txt' "the newest crash report is named"
}

test_event_file_is_rotated_past_the_size_cap() {
  make_instance "false"
  mkdir -p "$INST/logs"
  head -c 1100000 /dev/zero | tr '\0' 'x' > "$EVENTS"
  bash "$INST/start.sh" > /dev/null 2>&1
  assert_exists "$EVENTS.1" "the oversized file is kept as .1"
  assert_eq 5 "$(count_type jvm_start)" "and a fresh file starts"
}

run_tests
