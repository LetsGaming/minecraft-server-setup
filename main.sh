#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export USER="$USER"
export MAIN_DIR="$HOME"
export SCRIPT_DIR="$SCRIPT_DIR"

bash "$SCRIPT_DIR/setup/download_packages.sh"
node "$SCRIPT_DIR/setup/download/download_modpack.js"
node "$SCRIPT_DIR/setup/create_directories.js"
node "$SCRIPT_DIR/setup/unpack_modpack.js"
node "$SCRIPT_DIR/setup/copy_scripts.js"

echo "Cleaning up..."
sudo rm -rf "$SCRIPT_DIR/server-pack.zip"
echo "Setup completed successfully."

echo "Starting server..."
bash "$SCRIPT_DIR/start_server.sh"