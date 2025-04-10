#!/bin/bash
set -e

# Check if the user is root
if [ "$(id -u)" -eq 0 ]; then
  echo "You are running the script as root. Try the script like follows:"
  echo "sudo -u <username> bash main.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export USER="$USER"
export MAIN_DIR="$HOME"
export SCRIPT_DIR="$SCRIPT_DIR"

NO_START=false

# Argument parsing
for arg in "$@"; do
  case $arg in
    --no-start)
      NO_START=true
      shift
      ;;
    *)
      ;;
  esac
done

# Run setup scripts
bash "$SCRIPT_DIR/setup/download_packages.sh"
node "$SCRIPT_DIR/setup/download/download_modpack.js"
node "$SCRIPT_DIR/setup/create_directories.js"
node "$SCRIPT_DIR/setup/unpack_modpack.js"
node "$SCRIPT_DIR/setup/set_common_variables.js"
node "$SCRIPT_DIR/setup/copy_scripts.js"

echo "Cleaning up..."
sudo rm -rf "$SCRIPT_DIR/server-pack.zip"

echo "Setup completed successfully."

# Check for sudo privileges before starting the server
if [ "$NO_START" = false ]; then
  if ! sudo -v &>/dev/null; then
    echo "This script does not have sudo privileges, and the --no-start option was not set. The server will not start."
    exit 1
  else
    echo "Starting the server..."
    node "$SCRIPT_DIR/setup/start_server.js"
  fi
else
  echo "Remember to run the following commands to start the server:"
  echo "bash screen $MAIN_DIR/TARGET_DIR/scripts/MODPACK_NAME/start.sh"
fi
