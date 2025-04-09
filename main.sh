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

# Step 3: Create directories
bash "$SCRIPT_DIR/setup/create_directories.sh"

# Step 4: Unpack the modpack
bash "$SCRIPT_DIR/setup/unpack_modpack.sh"

# Step 5: Copy scripts
bash "$SCRIPT_DIR/setup/copy_scripts.sh"

echo "Setup completed successfully."
