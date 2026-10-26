#!/bin/bash
# Layout migration: detecting an old install layout (plan) and moving it (step 3).
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# True when systemd knows a unit file of that name. The exit status of
# `list-unit-files <name>` is not enough: it depends on the systemd version
# (older ones exit 0 with "0 unit files listed"), so the listing itself decides.
_unit_installed() {
  systemctl list-unit-files "$1" --no-legend 2> /dev/null | grep -q .
}

# Detects whether the install uses the old flat layout and needs directories moved.
detect_structure() {
  _old_instance_dir="$BASE_DIR/$INSTANCE_NAME"
  _new_instance_dir="$BASE_DIR/instances/$INSTANCE_NAME"
  _old_api_dir="$BASE_DIR/api-server"
  _new_api_dir="$BASE_DIR/services/api-server"
  # Both places an older install may have put the retired web interface.
  _old_manager_dir="$BASE_DIR/manager"
  _new_manager_dir="$BASE_DIR/services/manager"
  _manager_svc_name="$(basename "$BASE_DIR")-manager.service"

  NEEDS_INSTANCE_MOVE=false
  NEEDS_API_MOVE=false
  NEEDS_MANAGER_RETIRE=false

  # Instance move: SERVER_PATH still points at the old location and that dir exists
  if [[ "${SERVER_PATH:-}" == "$_old_instance_dir" && -d "$_old_instance_dir" && ! -d "$_new_instance_dir" ]]; then
    NEEDS_INSTANCE_MOVE=true
    info "MOVE    instances/$INSTANCE_NAME/  (${_old_instance_dir} → ${_new_instance_dir})"
  fi
  # Services moves: old dir exists and new dir does not
  if [[ -d "$_old_api_dir" && ! -d "$_new_api_dir" ]]; then
    NEEDS_API_MOVE=true
    info "MOVE    services/api-server/  (${_old_api_dir} → ${_new_api_dir})"
  fi
  # The web interface is retired rather than relocated: a unit that still exists
  # is a listening, credentialed service the operator believes is gone.
  if [[ -d "$_old_manager_dir" || -d "$_new_manager_dir" ]] \
     || _unit_installed "$_manager_svc_name"; then
    NEEDS_MANAGER_RETIRE=true
    info "RETIRE  the bundled web interface (service + deployment)"
  fi

  NEEDS_STRUCT_MIGRATION=false
  { $NEEDS_INSTANCE_MOVE || $NEEDS_API_MOVE || $NEEDS_MANAGER_RETIRE; } && NEEDS_STRUCT_MIGRATION=true
  return 0
}

# Step 3. Safe to skip (idempotent) when the new structure is already in place.
apply_structural_migration() {
  if [[ "$NEEDS_STRUCT_MIGRATION" == true ]]; then
    echo; echo -e "${BOLD}Step 3: Structural directory migration${NC}"

    # ── 3a: Instance dir: BASE_DIR/<instance>  →  BASE_DIR/instances/<instance>
    if $NEEDS_INSTANCE_MOVE; then
      log "Moving instance dir to instances/$INSTANCE_NAME/"
      run_cmd mkdir -p "$BASE_DIR/instances"
      run_cmd mv "$_old_instance_dir" "$_new_instance_dir"
      _S3_INSTANCE_MOVED=true
      info "Moved: $_old_instance_dir → $_new_instance_dir"

      # Update SERVER_PATH in variables.txt
      if ! $DRY_RUN; then
        sed -i "s|SERVER_PATH=\"${_old_instance_dir}\"|SERVER_PATH=\"${_new_instance_dir}\"|" "$VARS_FILE"
        _S3_VARS_PATCHED=true
      else
        echo "[DRY-RUN] sed -i SERVER_PATH in $VARS_FILE"
      fi
      info "Updated SERVER_PATH in variables.txt"

      # Patch the MC instance systemd service file (WorkingDirectory + ExecStart)
      _svc_file="/etc/systemd/system/${INSTANCE_NAME}.service"
      if [[ -f "$_svc_file" ]]; then
        if ! $DRY_RUN; then
          sudo sed -i "s|${_old_instance_dir}|${_new_instance_dir}|g" "$_svc_file"
          _S3_UNIT_FILE="$_svc_file"
          sudo systemctl daemon-reload
        else
          echo "[DRY-RUN] sudo sed -i paths in $_svc_file + daemon-reload"
        fi
        info "Patched: $_svc_file"
      fi

      # Patch api-server-config.json serverPath entries if present
      # (scriptsDir lives in BASE_DIR/scripts/ and does not change)
      for _cfg_dir in "$_new_api_dir" "$_old_api_dir"; do
        _api_cfg="$_cfg_dir/api-server-config.json"
        if [[ -f "$_api_cfg" ]]; then
          if ! $DRY_RUN; then
            # Use node to do a clean JSON edit — avoids broken JSON from sed on paths
            node -e "
              const fs = require('fs');
              const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
              const oldP = process.argv[2], newP = process.argv[3];
              for (const inst of Object.values(cfg.instances || {})) {
                if (inst.serverPath === oldP) inst.serverPath = newP;
              }
              fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
            " "$_api_cfg" "$_old_instance_dir" "$_new_instance_dir" 2>/dev/null && _S3_API_CFG_PATCHED=true || \
              warn "Could not auto-update serverPath in $_api_cfg — update manually"
          else
            echo "[DRY-RUN] node: update serverPath in $_api_cfg"
          fi
          info "Updated serverPath in $(basename "$_cfg_dir")/api-server-config.json"
          break
        fi
      done
    fi

    # ── 3b: api-server: BASE_DIR/api-server  →  BASE_DIR/services/api-server
    if $NEEDS_API_MOVE; then
      log "Moving api-server to services/api-server/"
      run_cmd mkdir -p "$BASE_DIR/services"
      run_cmd mv "$_old_api_dir" "$_new_api_dir"
      _S3_API_MOVED=true
      info "Moved: $_old_api_dir → $_new_api_dir"

      # Patch api-server systemd service file
      _api_svc_name="$(basename "$BASE_DIR")-api-server.service"
      _api_svc_file="/etc/systemd/system/$_api_svc_name"
      if [[ -f "$_api_svc_file" ]]; then
        if ! $DRY_RUN; then
          sudo sed -i "s|${_old_api_dir}|${_new_api_dir}|g" "$_api_svc_file"
          _S3_API_UNIT_FILE="$_api_svc_file"
          sudo systemctl daemon-reload
        else
          echo "[DRY-RUN] sudo sed -i paths in $_api_svc_file + daemon-reload"
        fi
        info "Patched: $_api_svc_file"
      fi
    fi

    # ── 3d: retire the bundled web interface
    #
    # It was superseded by the minecraft-bot dashboard, which reaches this host
    # through the API wrapper. Two halves, treated differently on purpose:
    #
    #   The systemd unit is removed automatically. A retired service that is
    #   still enabled keeps a port open and a credential file live on a host the
    #   operator believes is clean, and it comes back on the next reboot. That is
    #   the part that must not be left to a checklist.
    #
    #   The deployment directory is NOT deleted. It holds users.json — the only
    #   copy of credentials someone may still want to look at — and a migration
    #   script that silently shreds credentials is a migration script people stop
    #   trusting. It is renamed out of the way and the removal command printed.
    if $NEEDS_MANAGER_RETIRE; then
      log "Retiring the bundled web interface"

      _mgr_svc_file="/etc/systemd/system/$_manager_svc_name"
      if _unit_installed "$_manager_svc_name" || [[ -f "$_mgr_svc_file" ]]; then
        if ! $DRY_RUN; then
          sudo systemctl stop    "$_manager_svc_name" 2>/dev/null || true
          sudo systemctl disable "$_manager_svc_name" 2>/dev/null || true
          sudo rm -f "$_mgr_svc_file"
          sudo systemctl daemon-reload
        else
          echo "[DRY-RUN] sudo systemctl stop/disable $_manager_svc_name"
          echo "[DRY-RUN] sudo rm -f $_mgr_svc_file + daemon-reload"
        fi
        info "Stopped, disabled and removed: $_manager_svc_name"
      fi

      for _mgr_dir in "$_new_manager_dir" "$_old_manager_dir"; do
        [[ -d "$_mgr_dir" ]] || continue
        _retired_dir="${_mgr_dir}.retired"
        run_cmd mv "$_mgr_dir" "$_retired_dir"
        info "Moved aside: $_mgr_dir → $_retired_dir"
        warn "The retired deployment still holds credentials (users.json, .env)."
        warn "Once you no longer need them:"
        warn "  sudo shred -u \"$_retired_dir\"/src/config/users.json 2>/dev/null"
        warn "  sudo rm -rf \"$_retired_dir\""
      done

      info "Its features now live in the minecraft-bot dashboard — see"
      info "docs/retiring-web-interface.md"
    fi

    # Re-source variables.txt so the rest of the script sees the updated SERVER_PATH
    $DRY_RUN || source "$VARS_FILE"
    log "Structural migration complete"
  else
    echo; echo -e "${BOLD}Step 3: Structural directory migration${NC}"
    log "Already using new directory layout — nothing to move"
  fi
  return 0
}
