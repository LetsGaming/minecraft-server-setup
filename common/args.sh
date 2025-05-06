#!/bin/bash
set -e

# Usage:
#   1. Define ARG_OPTS before sourcing:
#        declare -A ARG_OPTS=(
#          ["--no-start"]="NO_START=false|Do not start the server"
#          ["--agree-eula"]="EULA=true|Accept the EULA"
#        )
#   2. Call: parse_args "$@"

# Map of arguments to var=value and description
declare -A ARG_OPTS
declare -A ARG_DEFAULTS
declare -A ARG_DESCRIPTIONS

parse_args() {
  for key in "${!ARG_OPTS[@]}"; do
    IFS='|' read -r val desc <<< "${ARG_OPTS[$key]}"
    var="${val%%=*}"
    default="${val#*=}"
    ARG_DEFAULTS["$key"]="$default"
    ARG_DESCRIPTIONS["$key"]="$desc"
    eval "$var=$default"
  done

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help)
        echo "Available options:"
        for key in "${!ARG_DESCRIPTIONS[@]}"; do
          printf "  %-15s %s (default: %s)\n" "$key" "${ARG_DESCRIPTIONS[$key]}" "${ARG_DEFAULTS[$key]}"
        done
        exit 0
        ;;
      *)
        if [[ -v ARG_OPTS["$1"] ]]; then
          var="${ARG_OPTS[$1]%%=*}"
          eval "$var=true"
        else
          echo "[ERROR] Unknown option: $1"
          echo "Use --help to see available options."
          exit 1
        fi
        ;;
    esac
    shift
  done
}
