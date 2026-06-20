#!/bin/bash
set -e

# Replaces start_server.js — launches the instance's start.sh inside a detached
# screen session, as the invoking user. Arguments are passed directly to
# `screen` (no interpolated shell string), so INSTANCE_NAME / paths cannot break
# out into the shell.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"
: "${USER:?USER not set}"

SCRIPT_PATH="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME/start.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "start.sh script not found at $SCRIPT_PATH" >&2
  exit 1
fi

sudo -u "$USER" screen -S "$INSTANCE_NAME" -dm bash "$SCRIPT_PATH"
echo "Server started in screen session '$INSTANCE_NAME'."
