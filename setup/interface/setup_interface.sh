#!/bin/bash
set -e
export INTERFACE_SETUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="https://github.com/LetsGaming/minecraft-server-manager.git"

# --- Clone Repository ---
if [ ! -d "$INTERFACE_SETUP_SCRIPT_DIR/minecraft-server-manager" ]; then
  git clone "$REPO_URL" "$INTERFACE_SETUP_SCRIPT_DIR/minecraft-server-manager"
fi

cd "$INTERFACE_SETUP_SCRIPT_DIR/minecraft-server-manager"

# -- Install Dependencies --
npm install
cd  "$INTERFACE_SETUP_SCRIPT_DIR"

# -- Setup Configuration --
node "$INTERFACE_SETUP_SCRIPT_DIR/variables/set_config.js"

node "$INTERFACE_SETUP_SCRIPT_DIR/management/move_interface.js"
node "$INTERFACE_SETUP_SCRIPT_DIR/management/create_service.js"

# -- Start Interface --
node "$INTERFACE_SETUP_SCRIPT_DIR/management/start_interface.js"

echo "[INFO] Interface setup complete."