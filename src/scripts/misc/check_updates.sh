#!/usr/bin/env bash
set -e

# Path to the JSON file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../common/downloaded_versions.json"

CURSEFORGE_FILE="$SCRIPT_DIR/../common/curseforge.txt"

if [[ ! -f "$CURSEFORGE_FILE" ]]; then
  echo "No curseforge.txt found."
  exit 0
fi

source "$CURSEFORGE_FILE"

# Read file into a single line with all whitespace removed
RAW=$(tr -d '\n\r\t ' < "$VERSION_FILE")

# === Parse modpack ===
modpack_id=""
modpack_file_id=""
if [[ "$RAW" =~ \"modpack\":\{([^\}]*)\} ]]; then
  MODPACK_ENTRY="${BASH_REMATCH[1]}"
  modpack_id=$(cut -d':' -f1 <<< "$MODPACK_ENTRY" | tr -d '"')
  modpack_file_id=$(cut -d':' -f2 <<< "$MODPACK_ENTRY")
fi

# === Parse mods ===
mod_ids=()
mod_file_ids=()
if [[ "$RAW" =~ \"mods\":\{([^\}]*)\} ]]; then
  MODS_BLOCK="${BASH_REMATCH[1]}"
  IFS=',' read -ra MOD_ENTRIES <<< "$MODS_BLOCK"
  for entry in "${MOD_ENTRIES[@]}"; do
    MOD_ID=$(cut -d':' -f1 <<< "$entry" | tr -d '"')
    FILE_ID=$(cut -d':' -f2 <<< "$entry")
    mod_ids+=("$MOD_ID")
    mod_file_ids+=("$FILE_ID")
  done
fi

# === Function to check for updates ===
# Returns 0 when an update exists, 1 when the file is current, 2 when the
# latest file could not be determined.
check_mod_update() {
    local mod_id="$1"
    local current_version="$2"

    local api_url="https://api.curseforge.com/v1/mods/$mod_id"

    # The key goes to curl as a config line on stdin so it never shows up in
    # the process list.
    local key_escaped=${API_KEY//\\/\\\\}
    key_escaped=${key_escaped//\"/\\\"}
    local response
    response=$(printf 'header = "x-api-key: %s"\n' "$key_escaped" |
        curl -sS -f --connect-timeout 5 --max-time 20 --config - "$api_url" 2> /dev/null) || return 2

    local latest_file_id
    latest_file_id=$(echo "$response" | grep -oP '"mainFileId": *\K[0-9]+' | head -n 1 || true)

    if [ -z "$latest_file_id" ]; then
        return 2
    fi

    if [[ "$current_version" != "$latest_file_id" ]]; then
        return 0
    else
        return 1
    fi
}

report_update() { # label id file_id
    local rc=0
    check_mod_update "$2" "$3" || rc=$?
    case "$rc" in
        0) echo "$1 update available!" ;;
        1) echo "$1 is up to date." ;;
        *) echo "$1: could not check for an update (the CurseForge request failed)."; FAILED=1 ;;
    esac
}

FAILED=0

# === Check modpack ===
if [[ -n "$modpack_id" && -n "$modpack_file_id" ]]; then
  report_update "Modpack" "$modpack_id" "$modpack_file_id"
else
  echo "No modpack found."
fi

# === Check all mods ===
for i in "${!mod_ids[@]}"; do
  report_update "Mod ${mod_ids[$i]}" "${mod_ids[$i]}" "${mod_file_ids[$i]}"
done

exit "$FAILED"
