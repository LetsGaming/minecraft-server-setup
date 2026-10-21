#!/bin/bash
set -e

ROUTE=""

_route_prompt() {
  local choice
  while true; do
    echo "How do you want to set up the server?"
    echo "  1) Quick setup (recommended)  2) Guided setup"
    read -r -p "Choose 1 or 2 [1]: " choice || choice=""
    case "$choice" in
      1 | "") ROUTE=default; return 0 ;;
      2) ROUTE=guided; return 0 ;;
      *) echo "Please answer 1 or 2." ;;
    esac
  done
}

select_route() {
  if [ "${DEFAULT_ROUTE:-false}" = true ] && [ "${GUIDED_ROUTE:-false}" = true ]; then
    ui_notice error "--default and --guided cannot be used together." >&2
    exit 1
  fi

  if [ "${DEFAULT_ROUTE:-false}" = true ]; then
    if ! ui_is_interactive && [ "${EULA:-false}" != true ]; then
      ui_notice error "--default without a terminal needs --agree-eula to accept the Minecraft EULA." >&2
      exit 1
    fi
    ROUTE=default
  elif [ "${GUIDED_ROUTE:-false}" = true ]; then
    if ! ui_is_interactive; then
      ui_notice error "Guided setup needs an interactive terminal; use --default --agree-eula or a prepared variables.json." >&2
      exit 1
    fi
    ROUTE=guided
  elif [ -f "$SCRIPT_DIR/variables.json" ] || ! ui_is_interactive; then
    ROUTE=power
  else
    _route_prompt
  fi
  export ROUTE
}

run_wizard() { # route
  echo "The guided setup is not available yet in this build." >&2
  exit 1
}
