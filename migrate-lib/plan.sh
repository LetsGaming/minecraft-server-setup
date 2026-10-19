#!/bin/bash
# From the plan to the decision: scope, nothing-to-do exit, summary and confirmation.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

compute_scope() {
  TOTAL_CHANGES=$(( REPLACED + ADDED + STALE ))
  # The Minecraft instance is only affected when the per-instance scripts change,
  # a per-instance npm install is due, or the instance directory itself moves.
  # Updating a shared service is invisible to the running java process, so a
  # services-only migration must not take the world down.

  NEEDS_INSTANCE_UPDATE=false
  if [[ $(( REPLACED + ADDED + STALE )) -gt 0 ]] \
     || $NEEDS_ANY_NPM_INSTALL || $NEEDS_INSTANCE_MOVE; then
    NEEDS_INSTANCE_UPDATE=true
  fi

  # The running server never reads its scripts folder: backups, updates and the
  # prune run as their own processes, and start.sh is only read when the server
  # starts. So replacing the scripts does not stop it; only moving its instance
  # folder does, or --restart. What must not overlap with the swap is an
  # operation that runs from those scripts, which the operation lock below keeps
  # out.
  NEEDS_SERVER_STOP=false
  if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] \
     && { $NEEDS_INSTANCE_MOVE || { $RESTART_SERVER && $NEEDS_INSTANCE_UPDATE; }; }; then
    NEEDS_SERVER_STOP=true
  fi
  return 0
}

exit_if_nothing_to_do() {
  if [[ $TOTAL_CHANGES -eq 0 && ${#NEW_VARS[@]} -eq 0 && "$NEEDS_ANY_NPM_INSTALL" != true \
     && "$NEEDS_STRUCT_MIGRATION" != true && "$NEEDS_API_UPDATE" != true \
     && ${#SM_PENDING[@]} -eq 0 ]]; then
    log "Everything is already up to date. Nothing to do."
    exit 0
  fi
  return 0
}

print_plan_summary() {
  echo
  SUMMARY="$REPLACED file(s) to update, $ADDED file(s) to add, ${#NEW_VARS[@]} variable(s) to add"
  [[ $STALE -gt 0 ]] && \
    SUMMARY="$SUMMARY, $STALE stale file(s) to remove"
  $NEEDS_API_UPDATE && SUMMARY="$SUMMARY, API wrapper to release $API_TO" || true
  [[ $JSON_CONFIG_ADDED -gt 0 ]] && \
    SUMMARY="$SUMMARY, $JSON_CONFIG_ADDED config key(s) to merge"
  "$NEEDS_INSTANCE_MOVE" && SUMMARY="$SUMMARY, instance dir to relocate" || true
  [[ ${#SM_PENDING[@]} -gt 0 ]] && SUMMARY="$SUMMARY, ${#SM_PENDING[@]} server migration(s)" || true
  info "$SUMMARY"
  echo
  return 0
}

confirm_plan() {
  if [[ "$SKIP_CONFIRM" != true ]]; then
    echo -e "${BOLD}This will:${NC}"
    echo "  1. Create a compressed archive backup of the scripts dir"
    if $NEEDS_SERVER_STOP; then
      echo "  2. Stop the Minecraft server"
    elif $SERVER_RUNNING; then
      echo "  2. Leave the Minecraft server running (nothing it has open is replaced)"
      $START_SCRIPT_CHANGED && echo "     start.sh changes: the new one applies at its next start (--restart to apply now)"
    fi
    if [[ "$NEEDS_STRUCT_MIGRATION" == true ]]; then
      echo "  3. Structural directory migration:"
      $NEEDS_INSTANCE_MOVE && echo "       mv  $BASE_DIR/$INSTANCE_NAME  →  $BASE_DIR/instances/$INSTANCE_NAME"
      $NEEDS_API_MOVE      && echo "       mv  $BASE_DIR/api-server  →  $BASE_DIR/services/api-server"
      $NEEDS_MANAGER_RETIRE && echo "       retire the bundled web interface (stop/disable/remove its unit,"
      $NEEDS_MANAGER_RETIRE && echo "              rename its deployment to *.retired — nothing is deleted)"
      $NEEDS_INSTANCE_MOVE && echo "     Updates SERVER_PATH in variables.txt and patches systemd unit files"
    fi
    if $NEEDS_INSTANCE_UPDATE; then
      echo "  4. Replace per-instance script files"
      echo "     Preserving: variables.txt, downloaded_versions.json, interface/,"
      echo "                 update/node_modules/, logs/, prune settings and journal,"
      echo "                 migration records and backups, upgrade status, operation locks"
      echo "     Clearing:   prune plans, scan cache and terrain tiles (rebuilt on demand)"
      [[ $STALE -gt 0 ]] && \
        echo "     Removing $STALE stale per-instance file(s)/component(s)"
      if [[ ${#JSON_CONFIGS[@]} -gt 0 ]]; then
        for entry in "${JSON_CONFIGS[@]}"; do
          f="${entry%%:*}"; nk="${entry##*:}"
          [[ "$nk" -gt 0 ]] \
            && echo "     Merging (not replacing): $f  ($nk new key(s))" \
            || echo "     Keeping unchanged: $f"
        done
      fi
    else
      echo "  4. Skip per-instance scripts (nothing changed — left untouched)"
    fi
    if $NEEDS_API_UPDATE; then
      echo "  5. Install API wrapper release $API_TO in $API_DIR"
      echo "     (downloaded and checked first; keeps api-server-config.json and logs/)"
    fi
    [[ $STALE -gt 0 ]] && \
      echo "     (all removed files remain available in the backup archive)"
    echo "  6. Add ${#NEW_VARS[@]} new variable(s) to variables.txt"
    if [[ ${#SM_PENDING[@]} -gt 0 ]]; then
      echo " 6b. Server migrations (the server is not restarted):"
      for _id in "${SM_PENDING[@]}"; do echo "       - $("sm_${_id}_describe")"; done
    fi
    $NEEDS_ANY_NPM_INSTALL && echo "  7. Run npm install in changed per-instance subdirs"
    $NEEDS_SERVER_STOP && echo "  9. Restart the Minecraft server"
    if $NEEDS_API_UPDATE && [[ "$SKIP_SERVICE_RESTART" != true ]]; then
      echo " 9b. Restart $API_SVC"
    fi
    echo
    read -rp "Proceed? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    echo
  fi
  return 0
}
