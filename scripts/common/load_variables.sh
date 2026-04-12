#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VARS_FILE="$SCRIPT_DIR/variables.txt"

if [ ! -f "$VARS_FILE" ]; then
    echo "Error: variables.txt not found in $SCRIPT_DIR"
    exit 1
fi

source "$VARS_FILE"

# Required variables
REQUIRED_VARS=(
    USER
    INSTANCE_NAME
    SERVER_PATH
    BACKUPS_PATH
    COMPRESSION_LEVEL
    MAX_STORAGE_GB
    DO_GENERATION_BACKUPS
    MAX_HOURLY_BACKUPS
    MAX_DAILY_BACKUPS
    MAX_WEEKLY_BACKUPS
    MAX_MONTHLY_BACKUPS
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in variables.txt"
        exit 1
    fi
done

# Export core variables
export USER INSTANCE_NAME SERVER_PATH
export BACKUPS_PATH COMPRESSION_LEVEL MAX_STORAGE_GB
export DO_GENERATION_BACKUPS
export MAX_HOURLY_BACKUPS MAX_DAILY_BACKUPS MAX_WEEKLY_BACKUPS MAX_MONTHLY_BACKUPS

# Export optional RCON variables (with defaults)
export USE_RCON="${USE_RCON:-false}"
export RCON_HOST="${RCON_HOST:-localhost}"
export RCON_PORT="${RCON_PORT:-25575}"
export RCON_PASSWORD="${RCON_PASSWORD:-}"

# Export optional webhook variables
export WEBHOOK_URL="${WEBHOOK_URL:-}"
export WEBHOOK_EVENTS="${WEBHOOK_EVENTS:-}"

# Export optional restart schedule variables
export RESTART_ENABLED="${RESTART_ENABLED:-false}"
export RESTART_INTERVAL_HOURS="${RESTART_INTERVAL_HOURS:-12}"
export RESTART_SKIP_IF_EMPTY="${RESTART_SKIP_IF_EMPTY:-true}"
export RESTART_WARN_SECONDS="${RESTART_WARN_SECONDS:-30}"
