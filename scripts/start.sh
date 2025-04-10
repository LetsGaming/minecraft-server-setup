#!/bin/bash
set -e

source "$(dirname "$0")/common/load_variables.sh"

echo "Starting $MODPACK_NAME server..."

sudo systemctl enable "$MODPACK_NAME".service
sudo systemctl start "$MODPACK_NAME".service

echo "$MODPACK_NAME server started successfully."