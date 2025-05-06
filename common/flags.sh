#!/bin/bash
set -e

set_flags_from_defaults() {
  if [ "$ACCEPT_ALL" = true ]; then
    [[ ! "$*" =~ "--no-start" ]] && NO_START=false
    [[ ! "$*" =~ "--agree-eula" ]] && EULA=true
    [[ ! "$*" =~ "--no-service" ]] && NO_SERVICE=false
    [[ ! "$*" =~ "--no-backup" ]] && NO_BACKUP=false
    [[ ! "$*" =~ "--interface" ]] && SETUP_INTERFACE=true
  fi
}

prompt_for_flags() {
  if [ "$ACCEPT_ALL" = false ]; then
    if [ "$NO_START" = false ]; then
      ask_yes_no "Do you wish to start the server?" && NO_START=false || NO_START=true
    fi
    if [ "$EULA" = false ]; then
      ask_yes_no "Do you agree to the EULA?" && EULA=true || EULA=false
    fi
    if [ "$NO_SERVICE" = false ]; then
      ask_yes_no "Do you want a systemd service?" && NO_SERVICE=false || NO_SERVICE=true
    fi
    if [ "$NO_BACKUP" = false ]; then
      ask_yes_no "Do you want a backup job?" && NO_BACKUP=false || NO_BACKUP=true
    fi
    if [ "$SETUP_INTERFACE" = false ]; then
      ask_yes_no "Do you want to setup the web interface?" && SETUP_INTERFACE=true || SETUP_INTERFACE=false
    fi
  fi
}
