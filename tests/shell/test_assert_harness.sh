#!/bin/bash
# Tests for run_tests in lib/assert.sh itself: a suite must not pass when a test
# stops early or checks nothing.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"

# run_inner <test bodies...>: a throwaway suite made of the given function
# definitions, run with the real harness. Sets OUT and RC.
run_inner() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-harness.XXXXXX")"
  {
    echo "source '$HERE/lib/assert.sh'"
    printf '%s\n' "$@"
    echo "run_tests"
  } > "$dir/inner.sh"
  OUT="$(TMPDIR="$dir" bash "$dir/inner.sh" 2>&1)"
  RC=$?
  rm -rf "$dir"
}

test_a_suite_of_passing_tests_passes() {
  run_inner 'test_one() { assert_eq 1 1 "fine"; }' 'test_two() { skip "x" "not here"; }'
  assert_rc 0 "$RC" "exit 0"
  assert_contains "$OUT" "RESULT pass=1 fail=0 skip=1" "counted"
}

test_a_failed_assertion_fails_the_suite() {
  run_inner 'test_one() { assert_eq 1 2 "wrong"; }'
  assert_nonzero "$RC" "exit status"
  assert_contains "$OUT" "fail=1" "counted"
}

test_a_test_that_exits_early_fails_the_suite() {
  run_inner 'test_aborts() { assert_eq 1 1 "before"; exit 3; assert_eq 1 1 "after"; }'
  assert_nonzero "$RC" "the suite fails"
  assert_contains "$OUT" "test_aborts stopped before its last statement (exit status 3)" "says which test and how"
  assert_contains "$OUT" "pass=1 fail=1" "the assertion that ran is still counted"
}

test_a_test_that_trips_errexit_fails_the_suite() {
  run_inner 'test_errexit() { set -e; assert_eq 1 1 "before"; false; assert_eq 1 1 "after"; }'
  assert_nonzero "$RC" "the suite fails"
  assert_contains "$OUT" "stopped before its last statement" "the lost assertion is reported"
}

test_a_test_without_assertions_fails_the_suite() {
  run_inner 'test_empty() { :; }'
  assert_nonzero "$RC" "the suite fails"
  assert_contains "$OUT" "test_empty made no assertions" "says why"
}

test_a_test_whose_last_command_returns_non_zero_is_not_a_failure() {
  run_inner 'test_last() { assert_eq 1 1 "fine"; false; }'
  assert_rc 0 "$RC" "completing is what counts"
}

run_tests
