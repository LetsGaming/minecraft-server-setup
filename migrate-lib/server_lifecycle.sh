#!/bin/bash
# Stopping the Minecraft server before a layout move (step 2) and starting it again (step 9).
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# Step 2.
stop_server() {
  if $NEEDS_SERVER_STOP; then
    echo; echo -e "${BOLD}Step 2: Stop server${NC}"
    log "Stopping '$INSTANCE_NAME'..."
    if ! $DRY_RUN; then
      if screen_session_exists "$INSTANCE_NAME"; then
        if [ "$(id -u)" -eq 0 ]; then
          sudo -u "$USER" screen -S "$INSTANCE_NAME" -p 0 -X stuff "/say Server updating scripts. Restarting shortly.$(printf \\r)" 2>/dev/null || true
        else
          screen -S "$INSTANCE_NAME" -p 0 -X stuff "/say Server updating scripts. Restarting shortly.$(printf \\r)" 2>/dev/null || true
        fi
        sleep 3
      fi
    fi
    _MIGRATE_STOPPED_SERVER=true
    run_cmd sudo systemctl stop "${INSTANCE_NAME}.service" 2>/dev/null || true
    if ! $DRY_RUN; then
      _server_down=false
      for _ in $(seq 1 30); do
        if ! systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null && ! screen_session_exists "$INSTANCE_NAME"; then
          _server_down=true
          break
        fi
        sleep 1
      done
      if ! $_server_down; then
        err "'$INSTANCE_NAME' is still running after the stop. Nothing was moved or replaced."
        exit 1
      fi
    fi
    sleep 2; log "Server stopped"
  elif $SERVER_RUNNING && [[ "$SKIP_STOP" == true ]]; then
    echo; echo -e "${BOLD}Step 2: Stop server${NC}"
    warn "Server running but --no-stop specified. Files replaced live."
  elif $SERVER_RUNNING; then
    echo; echo -e "${BOLD}Step 2: Stop server${NC}"
    log "Leaving '$INSTANCE_NAME' running — nothing it has open is replaced"
  fi
  return 0
}

# Step 9. Only when it was stopped by this migration.
restart_server() {
  if $NEEDS_SERVER_STOP; then
    echo; echo -e "${BOLD}Step 9: Restart server${NC}"
    log "Starting '$INSTANCE_NAME'..."
    run_cmd sudo systemctl start "${INSTANCE_NAME}.service"
    if ! $DRY_RUN; then
      sleep 5
      if systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then log "Server is running"
      elif screen_session_exists "$INSTANCE_NAME"; then log "Server is running (screen)"
      else warn "Server may still be starting. Check: systemctl status ${INSTANCE_NAME}.service"; fi
    fi
  fi
  return 0
}
