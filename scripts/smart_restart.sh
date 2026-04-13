#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"

# ── Args ──
FORCE=false
WARN_TIME="${RESTART_WARN_SECONDS:-30}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --warn=*) WARN_TIME="${1#*=}"; shift ;;
    --help)
      cat <<EOF
Usage: $0 [--force] [--warn=SECONDS]

Player-aware server restart. Skips the restart if no players are online
(unless --force is used or RESTART_SKIP_IF_EMPTY is false).

Options:
  --force          Restart even if no players are online
  --warn=SECONDS   Warning countdown (default: $WARN_TIME)
  --help           Show this help
EOF
      exit 0
      ;;
    *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Check if restart makes sense ──
if ! server_reachable; then
  echo "[INFO] Server is not running. Nothing to restart."
  exit 0
fi

PLAYER_COUNT=$(get_player_count 2>/dev/null || echo 0)

if [[ "$PLAYER_COUNT" -eq 0 && "$FORCE" != true && "$RESTART_SKIP_IF_EMPTY" == "true" ]]; then
  echo "[INFO] No players online. Restarting immediately (no warning needed)."
  save_and_wait 2>/dev/null || true
  systemctl_cmd restart
  echo "[INFO] Server restarted."
  notify_success "server_restart" "Server $INSTANCE_NAME restarted (no players online)."
  wait_for_server_ready 120 || true
  exit 0
fi

echo "[INFO] $PLAYER_COUNT player(s) online. Warning before restart..."

# ── Warning phase ──
if (( WARN_TIME > 10 )); then
  local_pre_warn=$(( WARN_TIME - 5 ))
  send_message "The server will §6restart§r in $WARN_TIME seconds. Please finish what you're doing."
  sleep "$local_pre_warn"
  countdown "Restart"
else
  send_message "The server will §6restart§r in $WARN_TIME seconds."
  sleep "$WARN_TIME"
fi

# ── Save and restart ──
save_and_wait 2>/dev/null || true
send_message "Server §6is restarting§r now!"
systemctl_cmd restart

echo "[INFO] Server restarted."
notify_success "server_restart" "Server $INSTANCE_NAME restarted ($PLAYER_COUNT players were online)."
wait_for_server_ready 120 || true
