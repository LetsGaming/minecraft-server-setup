#!/bin/bash

# Exit on error
set -e

# Load variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/variables.txt"

# Ensure required variables are defined
: "${MODPACK_NAME:?Missing MODPACK_NAME in variables.txt}"

# Step 1: Execute download_packages.sh
bash "$SCRIPT_DIR/setup/download_packages.sh"

# Step 2: Execute download_modpack.sh
bash "$SCRIPT_DIR/setup/download_modpack.sh"

# Step 3: Create directories (JS)
node "$SCRIPT_DIR/setup/create_directories.js"

# Step 4: Unpack the modpack (JS)
SCRIPT_DIR="$SCRIPT_DIR" node "$SCRIPT_DIR/setup/unpack_modpack.js"

# Step 5: Copy scripts (JS)
node "$SCRIPT_DIR/setup/copy_scripts.js"

echo "Setup completed successfully."
