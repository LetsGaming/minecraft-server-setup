#!/bin/bash
set -e

# Replaces move_files.js — moves the freshly-downloaded vanilla/Fabric server
# files from the temp dir into the instance dir, then drops in start.sh.
# cp -r + rm is used (rather than mv) so existing subdirectories in the instance
# dir are merged rather than colliding, matching the original recursive move.

: "${SCRIPT_DIR:?SCRIPT_DIR not set}"
: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

TMP_DIR="$SCRIPT_DIR/src/vanilla/temp"
INSTANCE_DIR="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME"

mkdir -p "$INSTANCE_DIR"

if [ -d "$TMP_DIR" ]; then
  shopt -s dotglob nullglob
  for entry in "$TMP_DIR"/*; do
    cp -r "$entry" "$INSTANCE_DIR/"
    rm -rf "$entry"
  done
  shopt -u dotglob nullglob
fi

START_SRC="$SCRIPT_DIR/src/vanilla/start.sh"
if [ -f "$START_SRC" ]; then
  cp "$START_SRC" "$INSTANCE_DIR/start.sh"
  echo "Copied start.sh from $START_SRC to $INSTANCE_DIR/start.sh"
else
  echo "Start script not found in source directory." >&2
  exit 1
fi
