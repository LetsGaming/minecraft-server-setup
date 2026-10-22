#!/bin/bash
set -e

ui_is_interactive() {
  [ "${MC_SETUP_FORCE_TTY:-}" = 1 ] && return 0
  [ -t 0 ] && [ -t 1 ]
}

ui_color_enabled() {
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-dumb}" != dumb ] || return 1
  [ "${MC_SETUP_FORCE_TTY:-}" = 1 ] && return 0
  [ -t 1 ]
}

ui_notice() { # severity message
  local severity="$1" message="$2" prefix="" color=""
  case "$severity" in
    adjusted) prefix="ADJUSTED:"; color=$'\033[33m' ;;
    warning) prefix="WARNING:"; color=$'\033[31m' ;;
    error) prefix="ERROR:"; color=$'\033[31m' ;;
    info) prefix="INFO:" ;;
    *) echo "ui_notice: unknown severity '$severity'" >&2; return 1 ;;
  esac
  if [ -n "$color" ] && ui_color_enabled; then
    printf '%s%s\033[0m %s\n' "$color" "$prefix" "$message"
  else
    printf '%s %s\n' "$prefix" "$message"
  fi
}
