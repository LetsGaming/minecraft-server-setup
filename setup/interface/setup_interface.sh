#!/bin/bash
set -e
export INTERFACE_SETUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="https://github.com/LetsGaming/minecraft-server-manager.git"

# --- Clone Repository ---
git clone "$REPO_URL"
cd minecraft-server-manager

# -- Install Dependencies --
npm install
cd ..

# -- Setup Configuration --
node variables/set_config.js

node management/move_interface.js
node management/create_service.js

# -- Start Interface --
node management/start_interface.js

echo "[INFO] Interface setup complete."