#!/bin/bash
set -e

# Replaces create_service.js — writes the per-instance systemd unit.
#
# SEC-03: the unit is streamed directly to `sudo tee <dest>` on stdin. No
# interpolated string is ever passed to a shell (no injection), and there is
# no world-writable /tmp staging file to race or symlink. This also removes
# the need for a broad `mv /tmp/...service /etc/systemd/system/` sudoers grant.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"
: "${USER:?USER not set}"

INSTANCE_DIR="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME"
START_SCRIPT="$INSTANCE_DIR/start.sh"
SERVICE_FILE="/etc/systemd/system/$INSTANCE_NAME.service"

SERVICE_CONTENT="[Unit]
Description=$INSTANCE_NAME Server
After=network.target

[Service]
User=$USER
Group=$USER
WorkingDirectory=$INSTANCE_DIR
ExecStart=/usr/bin/screen -DmS $INSTANCE_NAME /usr/bin/bash $START_SCRIPT
Restart=always
RestartSec=3s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
"

printf '%s' "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
sudo chmod 644 "$SERVICE_FILE"
echo "Systemd service file created successfully at $SERVICE_FILE"
