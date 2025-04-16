#!/bin/bash
set -e

# --- Root Check ---
if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root."
  echo "Try: sudo -u <username> bash main.sh"
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

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start)
      NO_START=true
      ;;
    --agree-eula)
      EULA=true
      ;;
    --no-service)
      NO_SERVICE=true
      ;;
    --no-backup)
      NO_BACKUP=true
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --agree-eula   Accept the EULA and set the variable."
      echo "  --no-start     Do not start the server after setup."
      echo "  --no-service   Skip creating the systemd service."
      echo "  --no-backup    Skip creating the backup job."
      echo "  --help         Show this help message."
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Try '$0 --help' for usage information."
      ;;
  esac
  shift
done

# --- Setup Steps ---
bash "$SCRIPT_DIR/setup/download/download_packages.sh"
node "$SCRIPT_DIR/setup/download/download_modpack.js"

node "$SCRIPT_DIR/setup/structure/create_directories.js"
node "$SCRIPT_DIR/setup/structure/unpack_modpack.js"

node "$SCRIPT_DIR/setup/variables/set_common_variables.js"
node "$SCRIPT_DIR/setup/variables/set_server_variables.js"
node "$SCRIPT_DIR/setup/variables/set_server_properties.js"

node "$SCRIPT_DIR/setup/structure/copy_scripts.js"

# --- Systemd Service ---
if [ "$NO_SERVICE" = false ]; then
  echo "Creating systemd service..."
  node "$SCRIPT_DIR/setup/management/create_service.js"
else
  echo "Skipping systemd service creation."
fi

if [ "$NO_BACKUP" = false ]; then
  echo "Creating backup job..."
  node "$SCRIPT_DIR/setup/management/create_backup_job.js"
else
  echo "Skipping backup job creation."
fi

# --- Cleanup ---
echo "Cleaning up..."
sudo rm -f "$SCRIPT_DIR/server-pack.zip"

echo "Setup completed successfully."

# --- EULA ---
if [ "$EULA" = true ]; then
  echo "EULA accepted. Setting variable"
  node "$SCRIPT_DIR/setup/management/agree_eula.js"
else
  echo "EULA not accepted. Please accept it before starting the server."
fi

# --- Start Server ---
if [ "$NO_START" = false ]; then
  if sudo -v &>/dev/null; then
    echo "Starting the server..."
    node "$SCRIPT_DIR/setup/management/start_server.js"
    if [ "$EULA" = false ]; then
      echo "Server started. Please accept the EULA by running:"
      echo "screen -r MODPACK_NAME"
      echo "Then, type 'I agree' and press Enter."
    fi
  else
    echo "Insufficient sudo privileges to start the server."
    exit 1
  fi
else
  echo "To start the server manually, run:"
  echo "bash $HOME/TARGET_DIR/scripts/MODPACK_NAME/start.sh"
  echo "Or:"
  echo "sudo systemctl start MODPACK_NAME.service"
fi
