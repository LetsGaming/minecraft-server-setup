#!/bin/bash
# Pre-migration checks: new scripts present, server running, compression, disk space.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

check_new_scripts_source() {
  echo -e "${BOLD}Pre-migration checks${NC}"

  REQUIRED_NEW_FILES=(
    "common/server_control.sh"
    "common/load_variables.sh"
    "common/rcon.js"
    "common/webhook.sh"
    "backup/backup.sh"
    "start.sh"
    "shutdown.sh"
    "update/update-server.js"
    "update/update-mods.js"
    "update/check-updates.js"
    "update/package.json"
  )
  check_ok=true
  for f in "${REQUIRED_NEW_FILES[@]}"; do
    [[ ! -f "$NEW_SCRIPTS_SOURCE/$f" ]] && { err "Missing in new scripts: $f"; check_ok=false; }
  done
  $check_ok && log "New scripts source is complete" || { err "Aborting."; exit 1; }
  return 0
}

# True when a screen session is named exactly <name>: a bare substring match
# would take a running "mc2" for "mc".
screen_session_exists() {
  local name_re
  name_re=$(printf '%s' "$1" | sed 's/[][\.*^$(){}+?|]/\\&/g')
  screen -list 2>/dev/null | grep -Eq "^[[:space:]]*[0-9]+\.${name_re}[[:space:]]"
}

detect_server_running() {
  # Server status
  SERVER_RUNNING=false
  if [[ -n "${INSTANCE_NAME:-}" ]]; then
    if screen_session_exists "$INSTANCE_NAME"; then
      SERVER_RUNNING=true; warn "Server '$INSTANCE_NAME' is currently running"
    elif systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then
      SERVER_RUNNING=true; warn "Server '$INSTANCE_NAME' is currently running (systemd)"
    else
      log "Server is not running"
    fi
  fi
  return 0
}

check_compression() {
  # Compression
  USE_ZSTD=false
  if command -v zstd &>/dev/null; then
    log "zstd available — backup will use zstd compression"; USE_ZSTD=true
  else
    warn "zstd not found — backup will use gzip"
  fi
  return 0
}

check_disk_space() {
  # Disk space
  AVAIL_MB=$(df -BM "$TARGET_SCRIPTS_DIR" | tail -1 | awk '{print $4}' | tr -d 'M')
  SCRIPTS_SIZE_MB=$(du -sm "$TARGET_SCRIPTS_DIR" | cut -f1)
  NEEDED_MB=$(( SCRIPTS_SIZE_MB / 2 + 10 ))
  (( AVAIL_MB < NEEDED_MB )) \
    && warn "Low disk space: ${AVAIL_MB}MB available, need ~${NEEDED_MB}MB for backup" \
    || log "Disk space OK (${AVAIL_MB}MB available)"
  return 0
}

run_preflight_checks() {
  check_new_scripts_source
  detect_server_running
  check_compression
  check_disk_space
  echo
  return 0
}
