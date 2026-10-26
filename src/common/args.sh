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
# Options that take a value, as --name=value or --name value: ["--name"]="VAR|description"
declare -A ARG_VALUE_OPTS

parse_args() {
  for key in "${!ARG_OPTS[@]}"; do
    IFS='|' read -r val desc <<< "${ARG_OPTS[$key]}"
    local var="${val%%=*}"
    local default="${val#*=}"
    ARG_DEFAULTS["$key"]="$default"
    ARG_DESCRIPTIONS["$key"]="$desc"
    # Use declare -g instead of eval for safety
    declare -g "$var=$default"
  done

  for key in "${!ARG_VALUE_OPTS[@]}"; do
    IFS='|' read -r val desc <<< "${ARG_VALUE_OPTS[$key]}"
    ARG_DESCRIPTIONS["$key"]="$desc"
    ARG_DEFAULTS["$key"]="none"
    declare -g "$val="
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
      --*=*)
        if [[ -v ARG_VALUE_OPTS["${1%%=*}"] ]]; then
          local vvar="${ARG_VALUE_OPTS[${1%%=*}]%%|*}"
          declare -g "$vvar=${1#*=}"
        else
          echo "[ERROR] Unknown option: $1"
          echo "Use --help to see available options."
          exit 1
        fi
        ;;
      *)
        if [[ -v ARG_VALUE_OPTS["$1"] ]]; then
          [[ $# -ge 2 ]] || { echo "[ERROR] $1 needs a value"; exit 1; }
          declare -g "${ARG_VALUE_OPTS[$1]%%|*}=$2"
          shift
        elif [[ -v ARG_OPTS["$1"] ]]; then
          local var="${ARG_OPTS[$1]%%=*}"
          declare -g "$var=true"
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
