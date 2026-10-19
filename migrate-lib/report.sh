#!/bin/bash
# The closing report: what was left running, what needs a manual step, what to do next.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

print_completion_report() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${GREEN}${BOLD}Migration complete!${NC}"
  echo
  info "Backup archive: $BACKUP_ARCHIVE"
  info "Remove once verified: rm -f '$BACKUP_ARCHIVE'"
  echo
  if [[ ${#SM_FAILED[@]} -gt 0 ]]; then
    err "Server migration(s) failed: ${SM_FAILED[*]}. They run again on the next migration."
    echo
  fi
  if [[ ${#SM_MANUAL[@]} -gt 0 ]]; then
    warn "Server migration(s) need a manual step (printed above): ${SM_MANUAL[*]}"
    echo
  fi
  if $SM_NEEDS_RESTART; then
    info "The instance's start.sh was updated. It takes effect the next time '$INSTANCE_NAME' starts."
    echo
  fi
  if $API_UPDATE_FAILED; then
    err "The API wrapper was not updated — it still runs ${API_FROM:-its previous release}."
    info "Check the output of Step 5, then run migrate.sh again."
    echo
  fi
  if [[ ${#RESTART_HINTS[@]} -gt 0 ]]; then
    warn "These services were updated but not restarted:"
    for _svc in "${RESTART_HINTS[@]}"; do info "  sudo systemctl restart $_svc"; done
    echo
  fi
  if $SERVER_RUNNING && ! $NEEDS_SERVER_STOP; then
    info "Minecraft instance '$INSTANCE_NAME' was left running — nothing it has open changed."
    if $START_SCRIPT_CHANGED; then
      info "start.sh changed: it applies at the server's next start, or run again with --restart."
    fi
    echo
  fi
  if $NEEDS_INSTANCE_UPDATE && ! $DRY_RUN; then
    for _sudoers in /etc/sudoers.d/mc-service-*-"${INSTANCE_NAME}"; do
      [[ -f "$_sudoers" ]] || continue
      _svc_user="${_sudoers##*/mc-service-}"
      _svc_user="${_svc_user%-"${INSTANCE_NAME}"}"
      warn "The scripts folder was replaced, so the ACLs the wrapper's user '$_svc_user' had on it are gone."
      info "Grant them again:"
      info "  sudo bash '$(dirname "$NEW_SCRIPTS_SOURCE")/setup/management/service_user.sh' --scripts-dir '$TARGET_SCRIPTS_DIR' --user '$_svc_user'"
      echo
    done
  fi
  if [[ ${#NEW_VARS[@]} -gt 0 ]]; then
    info "New features available — edit variables.txt to enable:"
    [[ " ${NEW_VARS[*]} " == *"USE_RCON"* ]]           && info "  • RCON:               USE_RCON=\"true\", RCON_PASSWORD"
    [[ " ${NEW_VARS[*]} " == *"WEBHOOK_URL"* ]]         && info "  • Webhooks:           WEBHOOK_URL=\"https://discord.com/...\""
    [[ " ${NEW_VARS[*]} " == *"RESTART_ENABLED"* ]]     && info "  • Scheduled restarts: RESTART_ENABLED=\"true\""
    [[ " ${NEW_VARS[*]} " == *"API_SERVER_ENABLED"* ]]  && info "  • minecraft-bot API:  API_SERVER_ENABLED=\"true\", API_SERVER_KEY"
    echo
  fi
  info "Scripts available:"
  info "  • rollback.sh               — Roll back to pre-update backup"
  info "  • smart_restart.sh          — Player-aware restart"
  info "  • manage.sh                 — Multi-instance management"
  info "  • update/update-server.js   — Update server + mods"
  info "  • services/api-server/      — minecraft-bot HTTP API wrapper"
  echo
  return 0
}
