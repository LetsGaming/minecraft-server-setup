#!/bin/bash

# Exit on error
set -e

: "${TARGET_DIR_NAME:?Missing TARGET_DIR_NAME in variables.txt}"
: "${MODPACK_NAME:?Missing MODPACK_NAME}"

# Ensure required variables are defined
BASE_DIR="$HOME/$TARGET_DIR_NAME"
SCRIPTS_DIR="$BASE_DIR/scripts/$MODPACK_NAME"

# Copy scripts into the target directory
cp -r "$SCRIPT_DIR/scripts/"* "$SCRIPTS_DIR/"
