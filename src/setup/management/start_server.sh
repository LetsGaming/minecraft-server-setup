#!/bin/bash
set -e

# Replaces start_server.js: starts the instance and reports it honestly.
#
# With a systemd unit (the default) the management start.sh enables and starts
# it; its exit status is the answer. With NO_SERVICE=true there is no unit, so
# the instance's own start.sh runs in a detached screen session as the invoking
# user, and the script checks the session is still there a moment later.
# Arguments go straight to `screen`, never through an interpolated shell
# string, so INSTANCE_NAME / paths cannot break out into the shell.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"
: "${USER:?USER not set}"

MANAGEMENT_START="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME/start.sh"
INSTANCE_START="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME/start.sh"

session_alive() {
  screen -list 2>/dev/null | grep -Eq "^[[:space:]]*[0-9]+\.${INSTANCE_NAME}[[:space:]]"
}

if [ "${NO_SERVICE:-false}" != "true" ]; then
  if [ ! -f "$MANAGEMENT_START" ]; then
    echo "start.sh script not found at $MANAGEMENT_START" >&2
    exit 1
  fi
  if ! bash "$MANAGEMENT_START"; then
    echo "The server did not start: $MANAGEMENT_START failed (see above)." >&2
    exit 1
  fi
  echo "Server started through its systemd service."
  exit 0
fi

if [ ! -f "$INSTANCE_START" ]; then
  echo "start.sh script not found at $INSTANCE_START" >&2
  exit 1
fi

sudo -u "$USER" screen -S "$INSTANCE_NAME" -dm bash "$INSTANCE_START"
sleep 3
if ! session_alive; then
  echo "The server did not stay up: its screen session '$INSTANCE_NAME' is gone after 3 seconds." >&2
  echo "Run it in the foreground to see why: bash $INSTANCE_START" >&2
  exit 1
fi
echo "Server started in screen session '$INSTANCE_NAME'."
