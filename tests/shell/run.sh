#!/bin/bash
# Runs every tests/shell/test_*.sh, then the node tests in tests/js, and
# reports a combined result with the number of cases that skipped themselves,
# so a green run on a host without flock, rsync or zstd is not mistaken for
# full coverage.
# Usage: bash tests/shell/run.sh [test_file.sh ...]
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

files=("$@")
run_js=false
if [[ ${#files[@]} -eq 0 ]]; then
  files=(test_*.sh)
  run_js=true
fi

failed=0
total_pass=0
total_fail=0
total_skip=0
for f in "${files[@]}"; do
  echo "== $f"
  out="$(bash "$f" 2>&1)" || failed=1
  printf '%s\n' "$out"
  result="$(printf '%s\n' "$out" | grep '^RESULT pass=' | tail -n1)"
  if [[ "$result" =~ pass=([0-9]+)\ fail=([0-9]+)\ skip=([0-9]+) ]]; then
    total_pass=$((total_pass + BASH_REMATCH[1]))
    total_fail=$((total_fail + BASH_REMATCH[2]))
    total_skip=$((total_skip + BASH_REMATCH[3]))
  fi
done

if [[ "$run_js" == true ]]; then
  if command -v node > /dev/null 2>&1; then
    echo "== tests/js"
    node --test ../js/*.test.cjs || failed=1
  else
    echo "== tests/js (skipped: node not found)"
  fi
fi

echo "SHELL TOTAL pass=$total_pass fail=$total_fail skip=$total_skip"
if [[ $failed -ne 0 ]]; then echo "SHELL TESTS FAILED"; exit 1; fi
echo "SHELL TESTS PASSED"
