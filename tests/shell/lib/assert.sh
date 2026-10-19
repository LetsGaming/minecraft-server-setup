#!/bin/bash
# Minimal assertion helpers. Each test file sources this, defines test_* functions,
# and calls run_tests. Results are tallied in the runner via the exit code.

PASS=0
FAIL=0
SKIP=0

_ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
_bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [[ -n "${2:-}" ]] && echo "         $2"; }

skip() { SKIP=$((SKIP + 1)); echo "  skip - $1 (cannot run on this host: $2)"; }

assert_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then _ok "$3"; else _bad "$3" "expected '$1', got '$2'"; fi
}
assert_rc() { # expected actual label
  if [[ "$1" == "$2" ]]; then _ok "$3"; else _bad "$3" "expected exit $1, got $2"; fi
}
assert_nonzero() { # actual label
  if [[ "$1" != "0" ]]; then _ok "$2"; else _bad "$2" "expected non-zero exit, got 0"; fi
}
assert_exists()  { if [[ -e "$1" || -L "$1" ]]; then _ok "$2"; else _bad "$2" "missing: $1"; fi; }
assert_missing() { if [[ ! -e "$1" && ! -L "$1" ]]; then _ok "$2"; else _bad "$2" "unexpectedly present: $1"; fi; }
assert_contains() { # haystack needle label
  if [[ "$1" == *"$2"* ]]; then _ok "$3"; else _bad "$3" "output does not contain '$2'"; fi
}
assert_not_contains() { # haystack needle label
  if [[ "$1" != *"$2"* ]]; then _ok "$3"; else _bad "$3" "output unexpectedly contains '$2'"; fi
}
assert_file_content() { # path expected label
  local got
  got="$(cat "$1" 2>/dev/null || echo '<unreadable>')"
  if [[ "$got" == "$2" ]]; then _ok "$3"; else _bad "$3" "expected '$2', got '$got'"; fi
}
assert_logged() { # needle label  (shim call log)
  if grep -qF -- "$1" "$SHIM_LOG" 2>/dev/null; then _ok "$2"; else _bad "$2" "shim log lacks '$1'"; fi
}
assert_not_logged() {
  if ! grep -qF -- "$1" "$SHIM_LOG" 2>/dev/null; then _ok "$2"; else _bad "$2" "shim log unexpectedly has '$1'"; fi
}

# Runs every test_* function of the sourcing file, each in its own subshell.
# A test counts as failed when it prints a FAIL line, when it never reached its
# last statement (an exit, or an errexit inherited from a sourced script, ended
# it with assertions still to run), or when it made no assertion at all.
run_tests() {
  local fn out rc ok bad skipped
  out="${TMPDIR:-/tmp}/.shelltest.$$"
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    echo "$fn"
    rc=0
    ( "$fn"; echo "  end  - $fn" ) > "$out" 2>&1 || rc=$?
    grep -v '^  end  - ' "$out"
    ok=$(grep -c '^  ok   - ' "$out" || true)
    bad=$(grep -c '^  FAIL - ' "$out" || true)
    skipped=$(grep -c '^  skip - ' "$out" || true)
    PASS=$((PASS + ok))
    FAIL=$((FAIL + bad))
    SKIP=$((SKIP + skipped))
    if ! grep -q "^  end  - $fn\$" "$out"; then
      FAIL=$((FAIL + 1))
      echo "  FAIL - $fn stopped before its last statement (exit status $rc)"
    elif (( ok + bad + skipped == 0 )); then
      FAIL=$((FAIL + 1))
      echo "  FAIL - $fn made no assertions"
    fi
    rm -f "$out"
  done
  echo "RESULT pass=$PASS fail=$FAIL skip=$SKIP"
  [[ "$FAIL" -eq 0 ]]
}
