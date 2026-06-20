#!/bin/bash
set -e

# Replaces create_service.js — writes the per-instance systemd unit. The unit is
# built in a temp file and moved into place with sudo (so no interpolated string
# is ever passed to a shell), using mktemp instead of a predictable
# /tmp/mc-service-<timestamp> name.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"
: "${USER:?USER not set}"

INSTANCE_DIR="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME"
START_SCRIPT="$INSTANCE_DIR/start.sh"
SERVICE_FILE="/etc/systemd/system/$INSTANCE_NAME.service"

TMP_FILE="$(mktemp /tmp/mc-service-XXXXXX)"
trap 'rm -f "$TMP_FILE"' EXIT

cat > "$TMP_FILE" <<EOF
[Unit]
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
EOF

sudo mv "$TMP_FILE" "$SERVICE_FILE"
sudo chmod 644 "$SERVICE_FILE"
echo "Systemd service file created successfully at $SERVICE_FILE"
