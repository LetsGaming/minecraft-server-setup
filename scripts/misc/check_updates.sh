#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../common/curseforge.txt"

# Validate curseforge.txt variables
required_vars=("API_KEY" "PACK_ID")
for var in "${required_vars[@]}"; do
  val="${!var:-}"
  if [[ -z "$val" || "$val" == "none" ]]; then
    echo "Error: Required variable '$var' is not set or is set to 'none' in curseforge.txt" >&2
    exit 1
  fi
done

# Handle MOD_IDS: if 'none' or not set, default to an empty string (array)
if [[ -z "${MOD_IDS:-}" || "$MOD_IDS" == "none" ]]; then
  MOD_IDS=""
fi

VERSIONS_FILE="$(dirname "${BASH_SOURCE[0]}")/../common/downloaded_versions.json"
BASE_URL="https://api.curseforge.com/v1"

JSON_MODE=false
ONLY_UPDATES=false

for arg in "$@"; do
  case "$arg" in
    --json) JSON_MODE=true ;;
    --only-updates) ONLY_UPDATES=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

extract_json_field() {
  local field="$1"
  echo "$2" | grep -o "\"$field\":[^,}]*" | head -n1 | cut -d':' -f2 | tr -d ' "'
}

get_stored_file_id() {
  local section="$1"
  local id="$2"
  grep -A5 "\"$section\"" "$VERSIONS_FILE" 2>/dev/null \
    | grep -A5 "\"$id\"" \
    | grep '"fileId":' \
    | head -n1 \
    | sed -E 's/.*"fileId":\s*([0-9]+).*/\1/' \
    || echo ""
}

check_modpack_update() {
  local response=$(curl -s -H "x-api-key: $API_KEY" "$BASE_URL/mods/$PACK_ID")
  local latest_file_id=$(extract_json_field "mainFileId" "$response")
  local stored_file_id=$(get_stored_file_id "modpack" "$PACK_ID")

  local update_needed=false
  [[ -z "$stored_file_id" || "$stored_file_id" != "$latest_file_id" ]] && update_needed=true

  if [[ "$JSON_MODE" == false ]]; then
    if $update_needed; then
      echo "➤ Modpack update available: new fileId $latest_file_id (stored: ${stored_file_id:-none})"
    else
      echo "✓ Modpack is up to date."
    fi
  fi

  if $ONLY_UPDATES && ! $update_needed; then
    echo ""
  else
    echo "\"modpack\":{\"id\":\"$PACK_ID\",\"update\":$update_needed,\"latestFileId\":$latest_file_id,\"storedFileId\":${stored_file_id:-null}}"
  fi

  $update_needed && return 0 || return 1
}

check_mod_updates() {
  IFS=',' read -ra MOD_ID_ARR <<< "${MOD_IDS//[\[\]\"]}"
  local mod_json_entries=()
  local update_any=false

  [[ "$JSON_MODE" == false ]] && echo "" && echo "Checking Mods..."

  for mod_id in "${MOD_ID_ARR[@]}"; do
    mod_id=$(echo "$mod_id" | xargs)
    [[ -z "$mod_id" || "$mod_id" == "none" ]] && continue

    local response=$(curl -s -H "x-api-key: $API_KEY" "$BASE_URL/mods/$mod_id")
    local latest_file_id=$(echo "$response" | grep -o '"latestFilesIndexes":\[[^]]*' | grep -o '"fileId":[0-9]*' | head -n1 | cut -d':' -f2)
    local stored_file_id=$(get_stored_file_id "mod" "$mod_id")

    local update_needed=false
    [[ -z "$stored_file_id" || "$stored_file_id" != "$latest_file_id" ]] && update_needed=true

    if [[ "$JSON_MODE" == false ]]; then
      if $update_needed; then
        echo "➤ [$mod_id] Update available: new fileId $latest_file_id (stored: ${stored_file_id:-none})"
      else
        echo "✓ [$mod_id] Up to date."
      fi
    fi

    if $ONLY_UPDATES && ! $update_needed; then
      continue
    fi

    mod_json_entries+=("\"$mod_id\":{\"update\":$update_needed,\"latestFileId\":$latest_file_id,\"storedFileId\":${stored_file_id:-null}}")
    $update_needed && update_any=true
  done

  if [[ ${#mod_json_entries[@]} -gt 0 ]]; then
    echo "\"mods\":{${mod_json_entries[*]}}"
  else
    echo "\"mods\":{}"
  fi

  $update_any && return 0 || return 1
}

if [[ ! -f "$VERSIONS_FILE" ]]; then
  echo "Error: downloaded_versions.json not found at $VERSIONS_FILE" >&2
  exit 1
fi

if $JSON_MODE; then
  modpack_json=$(check_modpack_update); modpack_status=$?
  mods_json=$(check_mod_updates); mods_status=$?

  [[ -z "$modpack_json" ]] && modpack_json="\"modpack\":{}"
  [[ -z "$mods_json" ]] && mods_json="\"mods\":{}"

  if [[ $modpack_status -eq 0 || $mods_status -eq 0 ]]; then
    updates_available=true
  else
    updates_available=false
  fi

  echo -n "{\"updatesAvailable\":$updates_available,$modpack_json,$mods_json}"
else
  check_modpack_update
  check_mod_updates
fi
