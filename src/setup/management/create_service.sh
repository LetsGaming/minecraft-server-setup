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
SCRIPTS_DIR="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME"
START_SCRIPT="$INSTANCE_DIR/start.sh"
SERVICE_FILE="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$INSTANCE_NAME.service"

# The backups folder, as the deployed scripts know it.
BACKUPS_DIR="$(sed -n 's/^BACKUPS_PATH="\(.*\)"$/\1/p' "$SCRIPTS_DIR/common/variables.txt" 2>/dev/null | head -n 1)"
[ -n "$BACKUPS_DIR" ] || BACKUPS_DIR="$MAIN_DIR/$TARGET_DIR_NAME/backups/$INSTANCE_NAME"

# systemd splits these on whitespace; a folder with one is left out of the list.
WRITABLE_PATHS=""
for dir in "$INSTANCE_DIR" "$BACKUPS_DIR"; do
  case "$dir" in
    *[[:space:]]*|none) ;;
    *) WRITABLE_PATHS="$WRITABLE_PATHS -$dir" ;;
  esac
done

SERVICE_CONTENT="[Unit]
Description=$INSTANCE_NAME Server
After=network.target
# Crash-loop protection: 5 failed starts inside 2 minutes and systemd stops
# retrying (StartLimitAction=none — it just gives up, nothing more drastic).
# These belong in [Unit]: systemd ignores them in [Service] (S-016), and with
# RestartSec=3s its own default 10s window never trips, so a broken server
# (e.g. a bad mod) restarts forever. Recovery after a trip: fix the cause,
# then \`systemctl reset-failed && systemctl start $INSTANCE_NAME\` (the
# wrapper's restart-instance action already does the reset-failed step).
StartLimitIntervalSec=120
StartLimitBurst=5
StartLimitAction=none

[Service]
User=$USER
Group=$USER
WorkingDirectory=$INSTANCE_DIR
ExecStart=/usr/bin/screen -DmS $INSTANCE_NAME /usr/bin/bash $START_SCRIPT
Restart=always
RestartSec=3s
LimitNOFILE=4096
# A big world can take longer than the 90 s default to write on the way down,
# and a SIGKILL in the middle of that corrupts region files. The ExecStop flush
# runs inside this window.
TimeoutStopSec=300
ExecStop=/usr/bin/bash $SCRIPTS_DIR/common/graceful_stop.sh
# Hardening that cannot get in the way of screen (setgid on Debian, so
# NoNewPrivileges stays off) or of the wrapper's sudo calls, which run outside
# this unit. The leading - ignores a folder that does not exist yet.
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${WRITABLE_PATHS# }

[Install]
WantedBy=multi-user.target
"

printf '%s' "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
sudo chmod 644 "$SERVICE_FILE"
echo "Systemd service file created successfully at $SERVICE_FILE"
