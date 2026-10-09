#!/bin/bash
# Runs every tests/shell/test_*.sh and reports a combined result.
# Usage: bash tests/shell/run.sh [test_file.sh ...]
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

files=("$@")
[[ ${#files[@]} -eq 0 ]] && files=(test_*.sh)

failed=0
for f in "${files[@]}"; do
  echo "== $f"
  bash "$f" || failed=1
done

if [[ $failed -ne 0 ]]; then echo "SHELL TESTS FAILED"; exit 1; fi
echo "SHELL TESTS PASSED"
