#!/bin/bash
set -e

# Validate variables.json once, up front, and export the two fields the setup
# steps need (INSTANCE_NAME, TARGET_DIR_NAME). Previously the first call to
# loadVariables() happened implicitly inside create_directories.js; now that the
# early steps are bash, we resolve + validate here instead. loadVariables()
# throws on an invalid config, so a bad variables.json fails fast here rather
# than after downloading a whole modpack.
resolve_instance_vars() {
  # Already resolved (e.g. both setup flows share run_setup_startup)
  if [[ -n "$INSTANCE_NAME" && -n "$TARGET_DIR_NAME" ]]; then
    return 0
  fi

  local out
  if ! out=$(node -e '
      const v = require(process.env.SCRIPT_DIR + "/src/setup/common/loadVariables")();
      process.stdout.write((v.INSTANCE_NAME || "") + "\n" + (v.TARGET_DIR_NAME || ""));
    ' 2>/dev/null); then
    error "variables.json is missing or invalid."
    error "Run 'bash main.sh --check' to see the exact problem."
    exit 1
  fi

  INSTANCE_NAME="$(printf '%s\n' "$out" | sed -n '1p')"
  TARGET_DIR_NAME="$(printf '%s\n' "$out" | sed -n '2p')"

  if [[ -z "$INSTANCE_NAME" || -z "$TARGET_DIR_NAME" ]]; then
    error "Could not read INSTANCE_NAME / TARGET_DIR_NAME from variables.json."
    exit 1
  fi

  export INSTANCE_NAME TARGET_DIR_NAME
}

run_modpack_setup() {
  run_setup_startup
  
  log "Downloading modpack..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/download/download_modpack.js\""

  log "Downloading additional mods..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/download/download_mods.js\""

  run_setup_steps

  log "Unpacking modpack..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/structure/unpack_modpack.js\""
}

run_vanilla_setup() {
  run_setup_startup

  log "Downloading Jabba..."
  run_or_echo "bash \"$SCRIPT_DIR/src/vanilla/download/install_jabba.sh\""

  log "Installing Java..."
  run_or_echo "node \"$SCRIPT_DIR/src/vanilla/download/install_java.js\""

  log "Downloading server jar..."
  run_or_echo "node \"$SCRIPT_DIR/src/vanilla/download/download_server.js\""

  run_setup_steps

  log "Setting additional variables..."
  run_or_echo "node \"$SCRIPT_DIR/src/vanilla/variables/set_vanilla_server_variables.js\""

  log "Moving server files..."
  run_or_echo "bash \"$SCRIPT_DIR/src/vanilla/structure/move_files.sh\""
}

run_setup_startup() {
  resolve_instance_vars

  log "Downloading required packages..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/download/download_packages.sh\""


  log "Creating server directory structure..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/structure/create_directories.sh\""
}

run_setup_steps() {
  log "Setting variables..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_common_variables.js\""
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_update_variables.js\""
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_server_variables.js\""

  log "Setting server.properties..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_server_properties.js\""

  log "Copying startup scripts..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/structure/copy_scripts.sh\""
}

run_optional_setup() {
  if [ "$NO_SERVICE" = false ]; then
    log "Creating systemd service..."
    run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_service.js\""
  else
    warn "Skipping systemd service creation (--no-service)."
  fi

  if [ "$NO_BACKUP" = false ]; then
    log "Creating backup job..."
    run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_backup_job.js\""
  else
    warn "Skipping backup job creation (--no-backup)."
  fi

  if [ "$EULA" = true ]; then
    log "EULA accepted. Applying configuration..."
    run_or_echo "bash \"$SCRIPT_DIR/src/setup/management/agree_eula.sh\""
  else
    warn "EULA not accepted. Please do so before launching the server."
  fi

  if [ "$SETUP_API_SERVER" = true ]; then
    log "Setting up minecraft-bot API wrapper service..."
    run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_api_server_service.js\""
  else
    # Still set up if enabled in variables.json and flag wasn't explicitly suppressed
    local api_enabled
    api_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.ENABLED || false)" 2>/dev/null)
    if [ "$api_enabled" = "true" ]; then
      log "API_SERVER.ENABLED=true — setting up minecraft-bot API wrapper service..."
      run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_api_server_service.js\""
    else
      warn "Skipping API wrapper setup (use --api-server or set API_SERVER.ENABLED=true)."
    fi
  fi

  if [ "$SETUP_INTERFACE" = true ]; then
    log "Setting up web interface..."
    run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_manager_service.js\""
  else
    # Still set up if enabled in variables.json and flag wasn't explicitly suppressed
    local iface_enabled
    iface_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.WEB_INTERFACE?.ENABLED || false)" 2>/dev/null)
    if [ "$iface_enabled" = "true" ]; then
      log "WEB_INTERFACE.ENABLED=true — setting up web interface..."
      run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_manager_service.js\""
    else
      warn "Skipping web interface setup (use --interface or set WEB_INTERFACE.ENABLED=true)."
    fi
  fi

  # Setup restart cron if enabled
  local restart_enabled
  restart_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.RESTART_SCHEDULE?.ENABLED || false)" 2>/dev/null)
  if [ "$restart_enabled" = "true" ]; then
    log "Setting up scheduled restart cron..."
    run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_restart_job.js\""
  fi
}

run_rollback() {
  warn "Setup failed — rolling back all changes..."

  # Read instance config from variables.json
  local instance_name target_dir
  instance_name=$(node -e "try{process.stdout.write(require('$SCRIPT_DIR/variables.json').INSTANCE_NAME||'')}catch(e){}" 2>/dev/null || true)
  target_dir=$(node -e "try{process.stdout.write(require('$SCRIPT_DIR/variables.json').TARGET_DIR_NAME||'')}catch(e){}" 2>/dev/null || true)

  if [[ -z "$instance_name" || -z "$target_dir" ]]; then
    warn "Could not read instance config from variables.json — skipping rollback."
    warn "You may need to clean up manually."
    return
  fi

  local base_dir="$MAIN_DIR/$target_dir"

  # Guard: never remove HOME or /
  if [[ "$base_dir" == "$MAIN_DIR" || "$base_dir" == "/" || -z "$base_dir" ]]; then
    warn "Unsafe base_dir detected ('$base_dir') — skipping directory removal."
  else
    # Stop and remove all created systemd services
    for svc in "$instance_name" "${target_dir}-api-server" "${target_dir}-manager"; do
      if sudo systemctl list-unit-files "${svc}.service" &>/dev/null; then
        log "Stopping service: ${svc}.service"
        sudo systemctl stop    "${svc}.service" 2>/dev/null || true
        sudo systemctl disable "${svc}.service" 2>/dev/null || true
      fi
      sudo rm -f "/etc/systemd/system/${svc}.service"
    done
    sudo systemctl daemon-reload 2>/dev/null || true

    # Remove cron entries that reference this instance's directory
    if crontab -l 2>/dev/null | grep -qF "$base_dir"; then
      log "Removing cron entries for $base_dir"
      crontab -l 2>/dev/null | grep -vF "$base_dir" | crontab - 2>/dev/null || true
    fi

    # Remove the entire instance directory tree
    # (contains server files, scripts, api-server, manager)
    if [[ -d "$base_dir" ]]; then
      log "Removing $base_dir"
      sudo rm -rf "$base_dir"
    fi
  fi

  # Remove source-tree artifacts written during setup
  local src_common="$SCRIPT_DIR/src/scripts/common"
  sudo rm -f "$src_common/variables.txt"
  sudo rm -f "$src_common/curseforge.txt"
  sudo rm -f "$src_common/downloaded_versions.json"
  sudo rm -rf "$SCRIPT_DIR/src/vanilla/temp"
  sudo rm -rf "$SCRIPT_DIR/src/setup/download/temp"

  warn "Rollback complete. Re-run the setup script when you are ready."
}

run_modpack_cleanup() {
  log "Cleaning up temporary files..."
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/setup/download/temp\""
  run_cleanup
}

run_vanilla_cleanup() {
  log "Cleaning up temporary files..."
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/vanilla/temp\""
  run_cleanup
}

run_cleanup() {
  # These files are written into the source tree during setup and contain
  # secrets (RCON password, API key, CurseForge key). They have already been
  # copied into the deployed instance dir, so remove the source-tree copies on
  # the success path too — previously only run_rollback removed variables.txt,
  # leaving secrets in the working tree after a successful run.
  run_or_echo "sudo rm -f \"$SCRIPT_DIR/src/scripts/common/variables.txt\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/scripts/common/downloaded_versions.json\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/scripts/common/curseforge.txt\""
}

maybe_start_server() {
  # Read instance/target names from variables.json for display purposes
  local instance_name target_dir
  instance_name=$(node -e "console.log(require('$SCRIPT_DIR/variables.json').INSTANCE_NAME)")
  target_dir=$(node -e "console.log(require('$SCRIPT_DIR/variables.json').TARGET_DIR_NAME)")

  if [ "$NO_START" = false ]; then
    if sudo -v &>/dev/null; then
      log "Starting the server..."
      run_or_echo "bash \"$SCRIPT_DIR/src/setup/management/start_server.sh\""
      if [ "$EULA" = false ]; then
        echo
        warn "Server started but EULA not yet accepted."
        echo "Attach to the server with:"
        echo "  screen -r $instance_name"
        echo "Then type 'I agree' and press Enter."
      fi
    else
      error "Insufficient sudo privileges to start the server."
      exit 1
    fi
  else
    log "Server will not be started (--no-start)."
    echo "You can start it manually with:"
    echo "  bash $HOME/$target_dir/scripts/$instance_name/start.sh"
    if [ "$NO_SERVICE" = false ]; then
      echo "Or use the systemd service with:"
      echo "  sudo systemctl start $instance_name.service"
    fi
  fi
}

# ── Preflight validation (--check mode) ──

run_preflight_check() {
  local errors=0
  local warnings=0

  echo "=== Preflight Check ==="
  echo

  # 1. Check variables.json
  echo "[CHECK] Validating variables.json..."
  if node -e "require('$SCRIPT_DIR/src/setup/common/loadVariables')()" 2>/dev/null; then
    echo "  ✓ variables.json is valid"
  else
    echo "  ✗ variables.json validation failed"
    node -e "require('$SCRIPT_DIR/src/setup/common/loadVariables')()" 2>&1 | sed 's/^/    /'
    errors=$((errors + 1))
  fi

  # 2. Check Node.js
  echo "[CHECK] Node.js..."
  if command -v node &>/dev/null; then
    local node_version
    node_version=$(node -v)
    echo "  ✓ Node.js $node_version found"
  else
    echo "  ✗ Node.js not found"
    errors=$((errors + 1))
  fi

  # 3. Check npm dependencies
  echo "[CHECK] npm dependencies..."
  if [ -d "$SCRIPT_DIR/node_modules" ]; then
    echo "  ✓ node_modules present"
  else
    echo "  ✗ node_modules not found — run 'npm install'"
    errors=$((errors + 1))
  fi

  # 4. Check required tools
  echo "[CHECK] Required tools..."
  for tool in screen rsync zstd tar curl; do
    if command -v "$tool" &>/dev/null; then
      echo "  ✓ $tool"
    else
      echo "  ✗ $tool not found"
      errors=$((errors + 1))
    fi
  done

  # 5. Check CurseForge API config (for modpack mode)
  echo "[CHECK] CurseForge config..."
  local cf_config="$SCRIPT_DIR/src/setup/download/json/curseforge_variables.json"
  if [ -f "$cf_config" ]; then
    local api_key pack_id
    api_key=$(node -e "console.log(require('$cf_config').api_key)" 2>/dev/null)
    pack_id=$(node -e "console.log(require('$cf_config').pack_id)" 2>/dev/null)
    if [[ "$api_key" == "none" || -z "$api_key" ]]; then
      echo "  ⚠ API key not set (required for modpack setup)"
      warnings=$((warnings + 1))
    else
      echo "  ✓ API key configured"
    fi
    if [[ "$pack_id" == "none" || -z "$pack_id" ]]; then
      echo "  ⚠ Pack ID not set (required for modpack setup)"
      warnings=$((warnings + 1))
    else
      echo "  ✓ Pack ID configured ($pack_id)"
    fi
  else
    echo "  ⚠ curseforge_variables.json not found"
    warnings=$((warnings + 1))
  fi

  # 6. Check disk space
  echo "[CHECK] Disk space..."
  local avail_gb
  avail_gb=$(df -BG "$HOME" | tail -1 | awk '{print $4}' | tr -d 'G')
  if (( avail_gb < 5 )); then
    echo "  ✗ Only ${avail_gb}GB available — need at least 5GB"
    errors=$((errors + 1))
  else
    echo "  ✓ ${avail_gb}GB available"
  fi

  # 7. Check RCON config
  echo "[CHECK] RCON config..."
  local use_rcon
  use_rcon=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.SERVER_CONTROL?.USE_RCON || false)" 2>/dev/null)
  if [ "$use_rcon" = "true" ]; then
    local rcon_pw
    rcon_pw=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.SERVER_CONTROL?.RCON_PASSWORD || '')" 2>/dev/null)
    if [[ -z "$rcon_pw" ]]; then
      echo "  ✗ RCON enabled but no password set"
      errors=$((errors + 1))
    else
      echo "  ✓ RCON enabled (port $(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.SERVER_CONTROL?.RCON_PORT || 25575)" 2>/dev/null))"
    fi
  else
    echo "  ✓ Using screen mode (RCON disabled)"
  fi

  # 8. Check webhook config
  echo "[CHECK] Webhook config..."
  local webhook_url
  webhook_url=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.NOTIFICATIONS?.WEBHOOK_URL || '')" 2>/dev/null)
  if [[ -n "$webhook_url" && "$webhook_url" != "none" ]]; then
    echo "  ✓ Webhook configured"
  else
    echo "  ⚠ No webhook URL configured (notifications disabled)"
    warnings=$((warnings + 1))
  fi

  # 9. Check API server config
  echo "[CHECK] API server config..."
  local api_enabled api_port api_key
  api_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.ENABLED || false)" 2>/dev/null)
  if [ "$api_enabled" = "true" ]; then
    api_port=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.PORT || 3000)" 2>/dev/null)
    api_key=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.API_KEY || '')" 2>/dev/null)
    if [[ -z "$api_key" ]]; then
      echo "  ⚠ API_SERVER enabled but no API_KEY set — wrapper will be unauthenticated"
      warnings=$((warnings + 1))
    else
      echo "  ✓ API server enabled (port $api_port, key configured)"
    fi
    # Check that node is available (required to run the wrapper)
    if ! command -v node &>/dev/null; then
      echo "  ✗ node not found — required to run the API wrapper"
      errors=$((errors + 1))
    fi
  else
    echo "  ✓ API server disabled (set API_SERVER.ENABLED=true to enable)"
  fi

  # 10. Check web interface config
  echo "[CHECK] Web interface config..."
  local wi_enabled wi_port
  wi_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.WEB_INTERFACE?.ENABLED || false)" 2>/dev/null)
  if [ "$wi_enabled" = "true" ]; then
    wi_port=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.WEB_INTERFACE?.PORT || 3001)" 2>/dev/null)
    echo "  ✓ Web interface enabled (port $wi_port)"
    # Check submodule is present
    if [ ! -f "$SCRIPT_DIR/src/scripts/minecraft-server-manager/app.js" ]; then
      echo "  ✗ scripts/minecraft-server-manager/ submodule not initialised"
      echo "    Run: git submodule update --init"
      errors=$((errors + 1))
    else
      echo "  ✓ Manager submodule present"
    fi
  else
    echo "  ✓ Web interface disabled (set WEB_INTERFACE.ENABLED=true to enable)"
  fi

  # Summary
  echo
  echo "=== Result ==="
  if [ $errors -eq 0 ]; then
    echo "✓ All checks passed ($warnings warning(s)). Ready to run setup."
    return 0
  else
    echo "✗ $errors error(s), $warnings warning(s). Fix errors before running setup."
    return 1
  fi
}
