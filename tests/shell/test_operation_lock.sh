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

try_mkdir_lock() { # kind -> sets RC, OUT; forces the mkdir fallback
  OUT="$( cd "$T/scripts" && source common/utils.sh && _have_flock() { return 1; } && acquire_operation_lock "$1" && echo "held=${MC_OPERATION_LOCK_HELD:-}" )" 2>&1
  RC=$?
}

test_mkdir_lock_is_not_taken_over_before_its_pid_is_written() {
  setup
  mkdir -p "$T/locks/operation_testinst.lock.d"
  try_mkdir_lock upgrade
  assert_rc 1 "$RC" "a fresh lock with no pid yet is busy, not abandoned (S-030)"
  touch -d "5 minutes ago" "$T/locks/operation_testinst.lock.d"
  try_mkdir_lock upgrade
  assert_rc 0 "$RC" "an old one without a pid is abandoned and taken over"
}

test_mkdir_lock_of_a_dead_holder_is_taken_over() {
  setup
  mkdir -p "$T/locks/operation_testinst.lock.d"
  echo 999999 > "$T/locks/operation_testinst.lock.d/pid"
  try_mkdir_lock upgrade
  assert_rc 0 "$RC" "the holder is gone"
}

run_tests
