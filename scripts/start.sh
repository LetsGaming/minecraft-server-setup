#!/bin/bash
set -e

source "$(dirname "$0")/common/load_variables.sh"

echo "Starting $INSTANCE_NAME server..."

SERVICE="${INSTANCE_NAME}.service"

if ! sudo -n systemctl enable "$SERVICE" 2>&1; then
  echo "[SUDO ERROR] Cannot enable service — passwordless sudo is not configured." >&2
  echo "[SUDO ERROR] See docs/sudoers-setup.md for instructions." >&2
  exit 1
fi

if ! sudo -n systemctl start "$SERVICE" 2>&1; then
  echo "[SUDO ERROR] Cannot start service — passwordless sudo is not configured." >&2
  echo "[SUDO ERROR] See docs/sudoers-setup.md for instructions." >&2
  exit 1
fi

echo "$INSTANCE_NAME server started successfully."
