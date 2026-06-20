#!/bin/bash
set -e

# Replaces create_directories.js — this is a plain `mkdir -p`, so it does not
# need a Node process or a loadVariables() round-trip. INSTANCE_NAME,
# TARGET_DIR_NAME and MAIN_DIR are exported by the setup driver
# (resolve_instance_vars in setup.sh validates variables.json once, up front).

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

BASE_DIR="$MAIN_DIR/$TARGET_DIR_NAME"

mkdir -p \
  "$BASE_DIR" \
  "$BASE_DIR/instances/$INSTANCE_NAME" \
  "$BASE_DIR/scripts/$INSTANCE_NAME" \
  "$BASE_DIR/services"

echo "Directories created successfully."
