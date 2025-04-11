#!/bin/bash
set -e

# Check if the script has sudo privileges
if ! sudo -v &>/dev/null; then
  echo "This script requires sudo privileges to run."
  exit 1
fi

source "$(dirname "$0")/common/load_variables.sh"

echo "Starting $MODPACK_NAME server..."

sudo systemctl enable "$MODPACK_NAME".service
sudo systemctl start "$MODPACK_NAME".service

echo "$MODPACK_NAME server started successfully."
