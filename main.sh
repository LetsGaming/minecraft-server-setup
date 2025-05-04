#!/bin/bash
set -e

# --- Root Check ---
if [ "$(id -u)" -eq 0 ]; then
  echo "[ERROR] Do not run this script as root."
  echo "Try: sudo -u <username> bash main.sh"
  exit 1
fi

# --- Require Sudo Privileges Upfront ---
if ! sudo -v; then
  echo "[ERROR] This script requires sudo privileges."
  exit 1
fi

# --- Environment Variables ---
export USER="$USER"
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MAIN_DIR="$HOME"

# --- Options ---
NO_START=false
EULA=false
NO_SERVICE=false
NO_BACKUP=false
DRY_RUN=false
VERBOSE=false
ACCEPT_ALL=false
SETUP_INTERFACE=false

# --- Logging Functions ---
log() {
  echo "[INFO] $1"
}

warn() {
  echo "[WARN] $1"
}

error() {
  echo "[ERROR] $1"
}

run_or_echo() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] $1"
  else
    eval "$1"
  fi
}

vlog() {
  if [ "$VERBOSE" = true ]; then
    log "$1"
  fi
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start)    NO_START=true ;;
    --agree-eula)  EULA=true ;;
    --no-service)  NO_SERVICE=true ;;
    --no-backup)   NO_BACKUP=true ;;
    --interface)   SETUP_INTERFACE=true ;;
    --dry-run)     DRY_RUN=true ;;
    --verbose)     VERBOSE=true ;;
    --y)           ACCEPT_ALL=true ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --agree-eula     Accept the EULA and set the variable."
      echo "  --no-start       Do not start the server after setup."
      echo "  --no-service     Skip creating the systemd service."
      echo "  --no-backup      Skip creating the backup job."
      echo "  --interface      Setup the web interface for the server."
      echo "  --dry-run        Only print what would be done."
      echo "  --verbose        Print additional logging info."
      echo "  --y              Accept all defaults and skip prompts (except for explicitly set flags)."
      echo "  --help           Show this help message."
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      echo "Try '$0 --help' for usage information."
      exit 1
      ;;
  esac
  shift
done

# --- Ask User for Input ---
ask_yes_no() {
  while true; do
    read -p "$1 [Y/n]: " yn
    case $yn in
        [Yy]* ) return 0 ;;
        [Nn]* ) return 1 ;;
        * ) echo "Please answer yes or no." ;;
    esac
  done
}

# --- Apply --y (Accept All) Defaults ---
if [ "$ACCEPT_ALL" = true ]; then
  # Only override if the user didn't explicitly set it
  if ! [[ "$*" =~ "--no-start" ]]; then NO_START=false; fi
  if ! [[ "$*" =~ "--agree-eula" ]]; then EULA=true; fi
  if ! [[ "$*" =~ "--no-service" ]]; then NO_SERVICE=false; fi
  if ! [[ "$*" =~ "--no-backup" ]]; then NO_BACKUP=false; fi
  if ! [[ "$*" =~ "--interface" ]]; then SETUP_INTERFACE=true; fi
fi

if [ "$ACCEPT_ALL" = false ]; then
  if [ "$NO_START" = false ]; then
    ask_yes_no "Do you wish to start the server?" && NO_START=false || NO_START=true
  fi
  if [ "$EULA" = false ]; then
    ask_yes_no "Do you agree to the EULA?" && EULA=true || EULA=false
  fi
  if [ "$NO_SERVICE" = false ]; then
    ask_yes_no "Do you want a systemd service?" && NO_SERVICE=false || NO_SERVICE=true
  fi
  if [ "$NO_BACKUP" = false ]; then
    ask_yes_no "Do you want a backup job?" && NO_BACKUP=false || NO_BACKUP=true
  fi
  if [ "$SETUP_INTERFACE" = false ]; then
    ask_yes_no "Do you want to setup the web interface?" && SETUP_INTERFACE=true || SETUP_INTERFACE=false
  fi
fi

# --- Setup Steps ---
log "Downloading required packages..."
run_or_echo "bash \"$SCRIPT_DIR/setup/download/download_packages.sh\""

log "Downloading modpack..."
run_or_echo "node \"$SCRIPT_DIR/setup/download/download_modpack.js\""

log "Downloading additional mods..."
run_or_echo "node \"$SCRIPT_DIR/setup/download/download_mods.js\""

log "Creating server directory structure..."
run_or_echo "node \"$SCRIPT_DIR/setup/structure/create_directories.js\""

log "Unpacking modpack..."
run_or_echo "node \"$SCRIPT_DIR/setup/structure/unpack_modpack.js\""

log "Setting common and server-specific variables..."
run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_common_variables.js\""
run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_update_variables.js\""
run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_server_variables.js\""

log "Setting server.properties..."
run_or_echo "node \"$SCRIPT_DIR/setup/variables/set_server_properties.js\""

log "Copying startup scripts..."
run_or_echo "node \"$SCRIPT_DIR/setup/structure/copy_scripts.js\""

# --- Systemd Service ---
if [ "$NO_SERVICE" = false ]; then
  log "Creating systemd service..."
  run_or_echo "node \"$SCRIPT_DIR/setup/management/create_service.js\""
else
  warn "Skipping systemd service creation (--no-service)."
fi

# --- Backup Job ---
if [ "$NO_BACKUP" = false ]; then
  log "Creating backup job..."
  run_or_echo "node \"$SCRIPT_DIR/setup/management/create_backup_job.js\""
else
  warn "Skipping backup job creation (--no-backup)."
fi

# --- Cleanup ---
log "Cleaning up temporary files..."
run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
run_or_echo "sudo rm -rf \"$SCRIPT_DIR/setup/download/temp\""

log "Setup completed successfully."

# --- EULA ---
if [ "$EULA" = true ]; then
  log "EULA accepted. Applying configuration..."
  run_or_echo "node \"$SCRIPT_DIR/setup/management/agree_eula.js\""
else
  warn "EULA not accepted. Please do so before launching the server."
fi

# --- Web Interface ---
if [ "$SETUP_INTERFACE" = true ]; then
  log "Setting up web interface..."
  run_or_echo "bash \"$SCRIPT_DIR/setup/interface/setup_interface.sh\""
else
  warn "Skipping web interface setup (--interface)."
fi

# --- Start Server ---
if [ "$NO_START" = false ]; then
  if sudo -v &>/dev/null; then
    log "Starting the server..."
    run_or_echo "node \"$SCRIPT_DIR/setup/management/start_server.js\""

    if [ "$EULA" = false ]; then
      echo
      warn "Server started but EULA not yet accepted."
      echo "Attach to the server with:"
      echo "  screen -r MODPACK_NAME"
      echo "Then type 'I agree' and press Enter."
    fi
  else
    error "Insufficient sudo privileges to start the server."
    exit 1
  fi
else
  log "Server will not be started (--no-start)."
  echo "You can start it manually with:"
  echo "  bash $HOME/TARGET_DIR/scripts/MODPACK_NAME/start.sh"
  if [ "$NO_SERVICE" = false ]; then
    echo "Or use the systemd service with:"
    echo "sudo systemctl start MODPACK_NAME.service"
  fi
fi
