#!/bin/bash
set -e

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

bash "$SCRIPT_DIR/setup/download_packages.sh"
node "$SCRIPT_DIR/setup/download/download_modpack.js"
node "$SCRIPT_DIR/setup/create_directories.js"
node "$SCRIPT_DIR/setup/unpack_modpack.js"
node "$SCRIPT_DIR/setup/set_common_variables.js"
node "$SCRIPT_DIR/setup/copy_scripts.js"

echo "Cleaning up..."
sudo rm -rf "$SCRIPT_DIR/server-pack.zip"

echo "Setup completed successfully."

if [ "$NO_START" = true ]; then
  echo "Remember to run the following commands to start the server:"
  echo "bash \$MAIN_DIR/TARGET_DIR/scripts/MODPACK_NAME/start.sh"
else
  echo "Starting the server..."
  node "$SCRIPT_DIR/setup/start_server.js"
fi
