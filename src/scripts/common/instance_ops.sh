#!/bin/bash
# Small server-control building blocks for the upgrade orchestrator
# (update/upgrade-server.js), so it reuses the same transport, locking-aware
# stop and running checks as rollback.sh instead of re-implementing them.
#
# Usage: instance_ops.sh <command> [args]
#   announce <message>   tell the players
#   stop                 save, stop the service and confirm it is down
#   start                start the service (clears a failed unit first)
#   halt                 stop the service without saving; for a server that
#                        is crash-looping and has nothing to save
#   running              exit 0 when the server is up, 1 when down, 2 unknown
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/server_control.sh"
source "$SCRIPT_DIR/archive_restore.sh"

wait_until_down() {
  local _
  for _ in $(seq 1 30); do
    server_is_running || return 0
    sleep 2
  done
  return 0
}

cmd="${1:-}"
shift || true

case "$cmd" in
  announce)
    send_message "${1:-}" 2> /dev/null || true
    ;;
  stop)
    if server_is_running; then
      save_and_wait || echo "[WARN] Save did not confirm; stopping anyway." >&2
    fi
    systemctl_cmd stop || { echo "[ERROR] Could not stop $INSTANCE_NAME.service." >&2; exit 1; }
    wait_until_down
    require_server_stopped || exit 1
    wait_for_notifications
    ;;
  halt)
    systemctl_cmd stop || { echo "[ERROR] Could not stop $INSTANCE_NAME.service." >&2; exit 1; }
    wait_until_down
    require_server_stopped || exit 1
    ;;
  start)
    systemctl_cmd start || exit 1
    ;;
  running)
    server_is_running
    exit $?
    ;;
  *)
    echo "Usage: $0 announce <message> | stop | halt | start | running" >&2
    exit 64
    ;;
esac
