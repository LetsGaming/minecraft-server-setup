#!/bin/bash
set -e

# Replaces copy_scripts.js — copies the runtime management scripts into this
# instance's scripts dir, then installs the update tooling's npm deps.
#
# The api-server is intentionally skipped: it is a shared, single-process
# deployment placed at <target>/services/api-server/ by
# create_api_server_service.js, not copied per instance.

: "${SCRIPT_DIR:?SCRIPT_DIR not set}"
: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

SOURCE_DIR="$SCRIPT_DIR/src/scripts"
SCRIPTS_DIR="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME"

mkdir -p "$SCRIPTS_DIR"

shopt -s dotglob nullglob
for entry in "$SOURCE_DIR"/*; do
  name="$(basename "$entry")"
  [ "$name" = "api-server" ] && continue  # deployed separately
  cp -r "$entry" "$SCRIPTS_DIR/"
done
shopt -u dotglob nullglob

echo "Scripts copied successfully."

# Install npm dependencies for the update tooling.
UPDATE_DIR="$SCRIPTS_DIR/update"
if [ -f "$UPDATE_DIR/package.json" ]; then
  echo "Installing npm dependencies in scripts/$INSTANCE_NAME/update..."
  if ( cd "$UPDATE_DIR" && npm install --omit=dev ); then
    echo "  done"
  else
    echo "  Failed to install in $UPDATE_DIR" >&2
    exit 1
  fi
fi

echo "All script dependencies installed."
