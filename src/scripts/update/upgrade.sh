#!/bin/bash
# Server version upgrade: stop, back up, install, start, and fall back if the
# new version does not come up. Holds the operation lock for the whole run, so
# a restore, rollback, backup or second upgrade cannot overlap it.
#
# Usage: upgrade.sh <version> [--expect-unavailable=a,b] [--countdown=<s>]
#                   [--start-timeout=<s>]
# Progress is NDJSON on stdout; the exit code is 0 only when the new version runs.
# Exit 75: another operation holds the lock.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/load_variables.sh"
source "$SCRIPT_DIR/../common/utils.sh"

acquire_operation_lock upgrade || exit 75

# With flock the lock lives on a file descriptor that exec hands to node.
# Without it the lock is a directory this shell must remove afterwards.
if _have_flock; then
  exec node "$SCRIPT_DIR/upgrade-server.js" "$@"
fi
node "$SCRIPT_DIR/upgrade-server.js" "$@"
rc=$?
release_operation_lock
exit $rc
