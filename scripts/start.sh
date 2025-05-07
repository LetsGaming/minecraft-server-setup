#!/bin/bash
set -e

# Check if the script has sudo privileges
if ! sudo -v &>/dev/null; then
  echo "This script requires sudo privileges to run."
  exit 1
fi

source "$(dirname "$0")/common/load_variables.sh"

echo "Starting $INSTANCE_NAME server..."

sudo systemctl enable "$INSTANCE_NAME".service
sudo systemctl start "$INSTANCE_NAME".service

echo "$INSTANCE_NAME server started successfully."
