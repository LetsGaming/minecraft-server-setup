#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/variables.txt" ]; then
    echo "Error: variables.txt not found in the common folder."
    exit 1
fi

# Load variables from the common folder
source "$SCRIPT_DIR/variables.txt"

if [ -z "$USER" ]; then
    echo "Error: USER is not set in variables.txt"
    exit 1
fi

# Check if MODPACK_NAME is set
if [ -z "$MODPACK_NAME" ]; then
    echo "Error: MODPACK_NAME is not set in variables.txt"
    exit 1
fi

if [ -z "$SERVER_PATH" ]; then
    echo "Error: SERVER_PATH is not set in variables.txt"
    exit 1
fi

if [ -z "$MAX_BACKUPS" ]; then
    echo "Error: MAX_BACKUPS is not set in variables.txt"
    echo "Setting default value to 3."
    echo "MAX_BACKUPS=3" >> variables.txt
    MAX_BACKUPS=3
fi

export USER="$USER"
export SERVER_PATH="$SERVER_PATH"
export MODPACK_NAME="$MODPACK_NAME"
export MAX_BACKUPS="$MAX_BACKUPS"