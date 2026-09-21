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
# Crash-loop protection: 5 failed starts inside 2 minutes and systemd stops
# retrying (StartLimitAction=none — it just gives up, nothing more drastic).
# Without this, RestartSec=3s can straddle systemd's own default 10s window
# and never trip the built-in limit, so a broken server (e.g. a bad mod)
# restarts forever until someone SSHes in and stops it by hand. Recovery
# after a trip: fix the cause, then \`systemctl reset-failed &&
# systemctl start $INSTANCE_NAME\` (the wrapper's restart-instance action
# already does the reset-failed step — see server_control.sh).
StartLimitIntervalSec=120
StartLimitBurst=5
StartLimitAction=none

[Install]
WantedBy=multi-user.target
"

printf '%s' "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
sudo chmod 644 "$SERVICE_FILE"
echo "Systemd service file created successfully at $SERVICE_FILE"
