#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export MAIN_DIR="$HOME"
export SCRIPT_DIR="$SCRIPT_DIR"

bash "$SCRIPT_DIR/setup/download_packages.sh"
bash "$SCRIPT_DIR/setup/download_modpack.sh"
node "$SCRIPT_DIR/setup/create_directories.js"
node "$SCRIPT_DIR/setup/unpack_modpack.js"
node "$SCRIPT_DIR/setup/copy_scripts.js"

sudo rm -rf "$MAIN_DIR/server-pack.zip"

echo "Setup completed successfully."
