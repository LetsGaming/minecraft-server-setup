#!/bin/bash
set -e

source "$(dirname "$0")/common/load_variables.sh"

echo "Starting $INSTANCE_NAME server..."

sudo systemctl enable "$INSTANCE_NAME".service
sudo systemctl start "$INSTANCE_NAME".service

echo "$INSTANCE_NAME server started successfully."
