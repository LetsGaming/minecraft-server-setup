#!/bin/bash

set -e

# Load variables from variables.txt
source "$(dirname "$0")/variables.txt"

# Check if MODPACK_NAME is set
if [ -z "$MODPACK_NAME" ]; then
    echo "Error: MODPACK_NAME is not set in variables.txt"
    exit 1
fi

if [ -z "$SERVER_PATH" ]; then
    echo "Error: SERVER_PATH is not set in variables.txt"
    exit 1
fi

export SERVER_PATH="$SERVER_PATH"
export MODPACK_NAME="$MODPACK_NAME"