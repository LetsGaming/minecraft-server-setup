#!/bin/bash
set -e

run_modpack_setup() {
  run_setup_startup
  
  log "Downloading modpack..."
  run_or_echo "node \"$SCRIPT_DIR/setup/download/download_modpack.js\""

  log "Downloading additional mods..."
  run_or_echo "node \"$SCRIPT_DIR/setup/download/download_mods.js\""

  run_setup_steps

  log "Unpacking modpack..."
  run_or_echo "node \"$SCRIPT_DIR/setup/structure/unpack_modpack.js\""
}

run_vanilla_setup() {
  run_setup_startup

  log "Downloading Jabba..."
  run_or_echo "bash \"$SCRIPT_DIR/vanilla/download/install_jabba.sh\""

  log "Installing Java..."
  run_or_echo "node \"$SCRIPT_DIR/vanilla/download/install_java.js\""

  log "Downloading server jar..."
  run_or_echo "node \"$SCRIPT_DIR/vanilla/download/download_server.js\""

  run_setup_steps

  log "Setting additional variables..."
  run_or_echo "node \"$SCRIPT_DIR/vanilla/variables/set_vanilla_server_variables.js\""

  log "Moving server files..."
  run_or_echo "node \"$SCRIPT_DIR/vanilla/structure/move_files.js\""
}

run_setup_startup() {
  log "Downloading required packages..."
  run_or_echo "bash \"$SCRIPT_DIR/setup/download/download_packages.sh\""


  log "Creating server directory structure..."
  run_or_echo "node \"$SCRIPT_DIR/setup/structure/create_directories.js\""
}

run_setup_steps() {
  log "Setting variables..."
  run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_common_variables.js\""
  run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_update_variables.js\""
  run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_server_variables.js\""

  log "Setting server.properties..."
  run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_server_properties.js\""

  log "Copying startup scripts..."
  run_or_echo "node \"$SCRIPT_DIR/setup/structure/copy_scripts.js\""
}

run_optional_setup() {
  if [ "$NO_SERVICE" = false ]; then
    log "Creating systemd service..."
    run_or_echo "node \"$SCRIPT_DIR/setup/management/create_service.js\""
  else
    warn "Skipping systemd service creation (--no-service)."
  fi

  if [ "$NO_BACKUP" = false ]; then
    log "Creating backup job..."
    run_or_echo "node \"$SCRIPT_DIR/setup/management/create_backup_job.js\""
  else
    warn "Skipping backup job creation (--no-backup)."
  fi

  if [ "$EULA" = true ]; then
    log "EULA accepted. Applying configuration..."
    run_or_echo "node \"$SCRIPT_DIR/setup/management/agree_eula.js\""
  else
    warn "EULA not accepted. Please do so before launching the server."
  fi

  if [ "$SETUP_INTERFACE" = true ]; then
    log "Setting up web interface..."
    run_or_echo "bash \"$SCRIPT_DIR/setup/interface/setup_interface.sh\""
  else
    warn "Skipping web interface setup (--interface)."
  fi

  # Setup restart cron if enabled
  local restart_enabled
  restart_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.RESTART_SCHEDULE?.ENABLED || false)" 2>/dev/null)
  if [ "$restart_enabled" = "true" ]; then
    log "Setting up scheduled restart cron..."
    run_or_echo "node \"$SCRIPT_DIR/setup/management/create_restart_job.js\""
  fi
}

run_modpack_cleanup() {
  log "Cleaning up temporary files..."
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/setup/download/temp\""
  run_cleanup
}

run_vanilla_cleanup() {
  log "Cleaning up temporary files..."
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/vanilla/temp\""
  run_cleanup
}

run_cleanup() {
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/scripts/common/downloaded_versions.json\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/scripts/common/curseforge.txt\""
}

maybe_start_server() {
  # Read instance/target names from variables.json for display purposes
  local instance_name target_dir
  instance_name=$(node -e "console.log(require('$SCRIPT_DIR/variables.json').INSTANCE_NAME)")
  target_dir=$(node -e "console.log(require('$SCRIPT_DIR/variables.json').TARGET_DIR_NAME)")

  if [ "$NO_START" = false ]; then
    if sudo -v &>/dev/null; then
      log "Starting the server..."
      run_or_echo "node \"$SCRIPT_DIR/setup/management/start_server.js\""
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
  if node -e "require('$SCRIPT_DIR/setup/common/loadVariables')()" 2>/dev/null; then
    echo "  ✓ variables.json is valid"
  else
    echo "  ✗ variables.json validation failed"
    node -e "require('$SCRIPT_DIR/setup/common/loadVariables')()" 2>&1 | sed 's/^/    /'
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
  local cf_config="$SCRIPT_DIR/setup/download/json/curseforge_variables.json"
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
