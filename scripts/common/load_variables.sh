#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from the common folder
source "$SCRIPT_DIR/variables.txt"

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