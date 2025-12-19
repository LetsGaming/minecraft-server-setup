#!/usr/bin/env bash
set -e

# Ensure script is sourced from other scripts
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file is meant to be sourced, not executed directly."
    exit 1
fi

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script requires sudo privileges. Please run with sudo."
        exit 1
    fi
}

# Logging setup
log_file_path=""

init_log_file() {
    local log_dir="$1"
    local log_file="$2"

    mkdir -p "$log_dir"
    log_file_path="$log_dir/$log_file"
}

log() {
    local level="$1"
    shift
    local msg
    msg="$(date +'%F %T') [$level] $*"
    echo "$msg"
    echo "$msg" >> "$log_file_path"
}

log_raw() {
    echo "$@" >> "$log_file_path"
}

# Monitors log for player joins and invokes a callback with the player name
on_player_join() {
    local log_path="$1"
    local callback="$2"

    if [[ ! -f "$log_path" ]]; then
        log "ERROR" "Log file not found: $log_path"
        return 1
    fi

    tail -n0 -F "$log_path" 2>/dev/null | while read -r line; do
        if [[ "$line" =~ \]:\ ([a-zA-Z0-9_]+)\ joined\ the\ game ]]; then
            local player="${BASH_REMATCH[1]}"
            "$callback" "$player"
        fi
    done
}
