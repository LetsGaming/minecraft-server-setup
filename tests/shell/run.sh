#!/bin/bash
# Runs every tests/shell/test_*.sh, then the node tests in tests/js, and
# reports a combined result.
# Usage: bash tests/shell/run.sh [test_file.sh ...]
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

files=("$@")
run_js=false
if [[ ${#files[@]} -eq 0 ]]; then
  files=(test_*.sh)
  run_js=true
fi

failed=0
for f in "${files[@]}"; do
  echo "== $f"
  bash "$f" || failed=1
done

if [[ "$run_js" == true ]]; then
  if command -v node > /dev/null 2>&1; then
    echo "== tests/js"
    node --test ../js/*.test.cjs || failed=1
  else
    echo "== tests/js (skipped: node not found)"
  fi
fi

if [[ $failed -ne 0 ]]; then echo "SHELL TESTS FAILED"; exit 1; fi
echo "SHELL TESTS PASSED"
