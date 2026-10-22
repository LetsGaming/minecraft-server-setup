#!/bin/bash
set -e

CORRECTIONS=()

corrections_reset() {
  CORRECTIONS=()
}

correction_add() { # severity subject asked chosen why
  case "$1" in
    adjusted | warning) ;;
    *) echo "correction_add: unknown severity '$1'" >&2; return 1 ;;
  esac
  CORRECTIONS+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"$'\x1f'"$5")
}

corrections_count() {
  echo "${#CORRECTIONS[@]}"
}

corrections_render() {
  local entry severity subject asked chosen why
  for entry in "${CORRECTIONS[@]}"; do
    IFS=$'\x1f' read -r severity subject asked chosen why <<< "$entry"
    ui_notice "$severity" "$subject"
    printf '  asked:  %s\n  chosen: %s\n  why:    %s\n' "$asked" "$chosen" "$why"
  done
}
