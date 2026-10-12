#!/bin/bash
# Tests for common/instance_ops.sh, the building blocks of the upgrade job.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() { make_fixture; trap cleanup_fixture EXIT; }
OPS="common/instance_ops.sh"

test_running_reports_the_server_state() {
  setup
  run_script "$OPS" running
  assert_rc 1 "$RC" "down when nothing runs"
  server_running
  run_script "$OPS" running
  assert_rc 0 "$RC" "up when the session exists"
}

test_stop_stops_the_service_and_confirms_it_is_down() {
  setup
  server_running
  run_script "$OPS" stop
  assert_rc 0 "$RC" "stop succeeds"
  assert_logged "systemctl stop testinst.service" "through systemctl"
  run_script "$OPS" running
  assert_rc 1 "$RC" "and the server is down afterwards"
}

test_stop_fails_when_the_service_will_not_stop() {
  setup
  server_running
  export SYSTEMCTL_STOP_RC=1
  run_script "$OPS" stop
  assert_nonzero "$RC" "a failed stop is a failure"
}

test_halt_does_not_try_to_save() {
  setup
  server_running
  run_script "$OPS" halt
  assert_rc 0 "$RC" "halt succeeds"
  assert_not_logged "save-all" "no save is attempted on a broken server"
}

test_start_starts_the_service() {
  setup
  run_script "$OPS" start
  assert_rc 0 "$RC" "start succeeds"
  assert_logged "systemctl start testinst.service" "through systemctl"
}

test_unknown_command_is_a_usage_error() {
  setup
  run_script "$OPS" frobnicate
  assert_rc 64 "$RC" "usage error"
}

run_tests
