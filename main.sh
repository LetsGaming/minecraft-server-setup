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
NO_SERVICE=false

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start)
      NO_START=true
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

# --- Start Server ---
if [ "$NO_START" = false ]; then
  if sudo -v &>/dev/null; then
    echo "Starting the server..."
    node "$SCRIPT_DIR/setup/management/start_server.js"
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
