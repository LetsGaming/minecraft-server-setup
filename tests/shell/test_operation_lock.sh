#!/bin/bash
# Tests for acquire_operation_lock in common/utils.sh.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() {
  make_fixture; trap cleanup_fixture EXIT
  export INSTANCE_LOCK_DIR="$T/locks"
  unset MC_OPERATION_LOCK_HELD
}

try_lock() { # kind -> sets RC, OUT
  OUT="$( cd "$T/scripts" && source common/utils.sh && acquire_operation_lock "$1" && echo "held=${MC_OPERATION_LOCK_HELD:-}" )" 2>&1
  RC=$?
}

test_free_slot_is_taken_and_exported() {
  setup
  try_lock upgrade
  assert_rc 0 "$RC" "acquired when nobody holds it"
  assert_contains "$OUT" "held=1" "children are told the lock is held"
  assert_file_content "$T/locks/operation_testinst.lock.kind" "upgrade" "the holder's kind is recorded"
}

test_busy_slot_names_the_running_operation() {
  setup
  mkdir -p "$T/locks"
  echo "restore" > "$T/locks/operation_testinst.lock.kind"
  export FLOCK_SHIM_BUSY=1
  try_lock upgrade
  assert_rc 1 "$RC" "refused while another operation runs"
  assert_contains "$OUT" "Another operation (restore)" "says which one"
}

test_a_child_of_the_holder_passes() {
  setup
  export FLOCK_SHIM_BUSY=1 MC_OPERATION_LOCK_HELD=1
  try_lock backup
  assert_rc 0 "$RC" "scripts the holder starts do not wait on it"
}

run_tests
