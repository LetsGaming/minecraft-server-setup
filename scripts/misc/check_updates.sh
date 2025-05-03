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
check_mod_update() {
    local mod_id="$1"
    local current_version="$2"

    local api_url="https://api.curseforge.com/v1/mods/$mod_id"
    
    # Fetch the mod details using curl with the API key
    local response=$(curl -s -H "x-api-key: $API_KEY" "$api_url")
    
    # Extract the mainFileId from the response
    local latest_file_id=$(echo "$response" | grep -oP '"mainFileId": *([0-9]+)' | sed -E 's/"mainFileId": *([0-9]+)/\1/')

    # Ensure we have a valid file ID
    if [ -z "$latest_file_id" ]; then
        echo "Failed to fetch the latest file ID."
        return 
    fi

    # Check if the latest file ID matches the current version's file ID
    if [[ "$current_version" != "$latest_file_id" ]]; then
        return 0
    else
        return 1
    fi
}

# === Check modpack ===
if [[ -n "$modpack_id" && -n "$modpack_file_id" ]]; then
  check_mod_update "$modpack_id" "$modpack_file_id"
  if [[ $? -eq 0 ]]; then
    echo "Modpack update available!"
  else
    echo "Modpack is up to date."
  fi
else
  echo "No modpack found."
fi

# === Check all mods ===
for i in "${!mod_ids[@]}"; do
  mod_id="${mod_ids[$i]}"
  mod_file_id="${mod_file_ids[$i]}"

  check_mod_update "$mod_id" "$mod_file_id"
  if [[ $? -eq 0 ]]; then
    echo "Mod $mod_id update available!"
  else
    echo "Mod $mod_id is up to date."
  fi
done
