#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/load_variables.sh"

if [[ "$RESTART_ENABLED" != "true" ]]; then
  exit 0
fi

SMART_RESTART="$SCRIPT_DIR/../smart_restart.sh"

if [[ ! -f "$SMART_RESTART" ]]; then
  echo "[ERROR] smart_restart.sh not found at $SMART_RESTART"
  exit 1
fi

echo "[$(date +'%F %T')] Running scheduled restart..."
bash "$SMART_RESTART" --warn="$RESTART_WARN_SECONDS"
