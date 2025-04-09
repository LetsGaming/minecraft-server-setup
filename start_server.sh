#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

variables=$(node "$SCRIPT_DIR/setup/common/loadVariables.js")
MODPACK_NAME=$(echo "$variables" | jq -r .MODPACK_NAME)

echo "Starting $MODPACK_NAME server..."

sudo systemctl enable "$MODPACK_NAME".service
sudo systemctl start "$MODPACK_NAME".service

echo "$MODPACK_NAME server started successfully."