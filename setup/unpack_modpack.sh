#!/bin/bash

# Exit on error
set -e

# Ensure required variables are defined
: "${SCRIPT_DIR:?Missing SCRIPT_DIR}"

# Unpack the modpack if the zip file exists
UNPACK_SOURCE="$SCRIPT_DIR/server-pack.zip"
if [ -f "$UNPACK_SOURCE" ]; then
    unzip -o "$UNPACK_SOURCE" -d "$MODPACK_DIR"
else
    echo "Modpack archive $UNPACK_SOURCE not found."
    exit 1
fi
