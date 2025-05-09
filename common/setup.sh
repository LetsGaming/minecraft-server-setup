#!/bin/bash
set -e

run_modpack_setup() {
  log "Downloading required packages..."
  run_or_echo "bash \"$SCRIPT_DIR/setup/download/download_packages.sh\""

  log "Downloading modpack..."
  run_or_echo "node \"$SCRIPT_DIR/setup/download/download_modpack.js\""

  log "Downloading additional mods..."
  run_or_echo "node \"$SCRIPT_DIR/setup/download/download_mods.js\""

  run_setup_steps

  log "Unpacking modpack..."
  run_or_echo "node \"$SCRIPT_DIR/setup/structure/unpack_modpack.js\""
}

run_vanilla_setup() {
  log "Downloading required packages..."
  run_or_echo "bash \"$SCRIPT_DIR/setup/download/download_packages.sh\""

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

run_setup_steps() {
  log "Creating server directory structure..."
  run_or_echo "node \"$SCRIPT_DIR/setup/structure/create_directories.js\""

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
  if [ "$NO_START" = false ]; then
    if sudo -v &>/dev/null; then
      log "Starting the server..."
      run_or_echo "node \"$SCRIPT_DIR/setup/management/start_server.js\""
      if [ "$EULA" = false ]; then
        echo
        warn "Server started but EULA not yet accepted."
        echo "Attach to the server with:"
        echo "  screen -r INSTANCE_NAME"
        echo "Then type 'I agree' and press Enter."
      fi
    else
      error "Insufficient sudo privileges to start the server."
      exit 1
    fi
  else
    log "Server will not be started (--no-start)."
    echo "You can start it manually with:"
    echo "  bash $HOME/TARGET_DIR/scripts/INSTANCE_NAME/start.sh"
    if [ "$NO_SERVICE" = false ]; then
      echo "Or use the systemd service with:"
      echo "  sudo systemctl start INSTANCE_NAME.service"
    fi
  fi
}
