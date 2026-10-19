#!/bin/bash
# The API wrapper: check against its pinned release (plan), install (step 5), restart (step 9b).
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

RESTART_HINTS=()

# Only an install that exists is updated: the wrapper is optional. Before the
# structural move it still sits at <install-root>/api-server/.
plan_api_wrapper() {
  _api_check_dir="$API_DIR"
  [[ ! -d "$_api_check_dir" && -d "$BASE_DIR/api-server" ]] && _api_check_dir="$BASE_DIR/api-server"
  if [[ -f "$_api_check_dir/index.js" ]]; then
    if ! command -v node &>/dev/null; then
      warn "node not found — cannot check the API wrapper against its pinned release"
    elif _api_line=$(node "$API_INSTALLER" --check --dir "$_api_check_dir" 2>&1); then
      _api_state=$(sed -n 's/.*state=\([a-z]*\).*/\1/p' <<<"$_api_line")
      API_FROM=$(sed -n 's/.*installed=\([^ ]*\).*/\1/p' <<<"$_api_line")
      API_TO=$(sed -n 's/.*pinned=\([^ ]*\).*/\1/p' <<<"$_api_line")
      case "$_api_state" in
        current)
          info "KEEP    services/api-server/  (release $API_TO, as pinned)" ;;
        outdated)
          info "UPDATE  services/api-server/  ($API_FROM → release $API_TO)"
          NEEDS_API_UPDATE=true ;;
        unmanaged)
          info "UPDATE  services/api-server/  (copy from before releases, $API_FROM → release $API_TO)"
          NEEDS_API_UPDATE=true ;;
      esac
    else
      warn "Could not check the API wrapper: $_api_line"
    fi
  fi
  return 0
}

# Step 5. install_api_server.js stages and checks the release before it touches
# the install, so a failure here leaves the running wrapper as it was.
update_api_wrapper() {
  # install_api_server.js stages and checks the release before it touches the
  # install, so a failure here leaves the running wrapper as it was.

  if $NEEDS_API_UPDATE; then
    echo; echo -e "${BOLD}Step 5: API wrapper${NC}"
    _api_args=(--dir "$API_DIR")
    $DRY_RUN && _api_args+=(--dry-run)
    if node "$API_INSTALLER" "${_api_args[@]}"; then
      log "API wrapper is on release $API_TO"
    else
      err "Installing API wrapper release $API_TO failed — the previous install is unchanged"
      API_UPDATE_FAILED=true
    fi
  fi
  return 0
}

# Step 9b. Only after a successful update. The Minecraft instance is unaffected.
restart_api_wrapper() {
  if $NEEDS_API_UPDATE && ! $API_UPDATE_FAILED; then
    echo; echo -e "${BOLD}Step 9b: Restart the API wrapper${NC}"
    if [[ "$SKIP_SERVICE_RESTART" == true ]]; then
      info "Skipped (--no-service-restart): $API_SVC"
      RESTART_HINTS+=("$API_SVC")
    elif [[ -f "/etc/systemd/system/$API_SVC" ]]; then
      log "Restarting $API_SVC"
      run_cmd sudo systemctl restart "$API_SVC"
      if ! $DRY_RUN; then
        sleep 2
        systemctl is-active "$API_SVC" &>/dev/null \
          && info "  $API_SVC is active" \
          || warn "  $API_SVC did not come up — check: systemctl status $API_SVC"
      fi
    else
      warn "No systemd unit $API_SVC — restart services/api-server manually"
      RESTART_HINTS+=("$API_SVC")
    fi
  fi
  return 0
}
