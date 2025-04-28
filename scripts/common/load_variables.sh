#!/bin/bash

set -e

# Get the absolute path of the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VARS_FILE="$SCRIPT_DIR/variables.txt"

if [ ! -f "$VARS_FILE" ]; then
    echo "Error: variables.txt not found in $SCRIPT_DIR"
    exit 1
fi

# Load variables from file
source "$VARS_FILE"

# Required variables
REQUIRED_VARS=(
    USER
    MODPACK_NAME
    SERVER_PATH
    COMPRESSION_LEVEL
    MAX_STORAGE_GB
    DO_GENERATION_BACKUPS
    MAX_HOURLY_BACKUPS
    MAX_DAILY_BACKUPS
    MAX_WEEKLY_BACKUPS
    MAX_MONTHLY_BACKUPS
)

# Validate all required variables are set
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in variables.txt"
        exit 1
    fi
done

# Export them
export USER
export MODPACK_NAME
export SERVER_PATH
export COMPRESSION_LEVEL
export DO_GENERATION_BACKUPS
export MAX_STORAGE_GB
export MAX_HOURLY_BACKUPS
export MAX_DAILY_BACKUPS
export MAX_WEEKLY_BACKUPS
export MAX_MONTHLY_BACKUPS
