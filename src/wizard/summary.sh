#!/bin/bash
# Summary, EULA step, final and failure screens for the Default and Guided routes.
# Expects ui.sh, corrections.sh, detect.sh and prompts.sh to be sourced, plus the globals
# ANSWERS, CHOSEN_HEAP_MB, CHOSEN_SERVER_PORT and WIZARD_TARGET_DIR_NAME set by the route.

EULA_URL="https://aka.ms/MinecraftEULA"

_summary_server_type() {
  case "${ANSWERS[server_kind]-fabric}" in
    vanilla) echo "Vanilla Minecraft (no mods)" ;;
    modpack) echo "CurseForge modpack" ;;
    *) echo "Fabric (supports mods)" ;;
  esac
}

_summary_mod_groups() {
  case "${ANSWERS[server_kind]-fabric}" in
    vanilla) echo "none" ;;
    modpack) echo "as defined by the modpack" ;;
    *)
      local groups="performance and utility"
      case " ${ANSWERS[optional_mods]-} " in *" optional "*) groups="$groups, optional" ;; esac
      echo "$groups"
      ;;
  esac
}

_summary_onoff() { # value-that-means-on
  if [ "$1" = true ]; then echo "on"; else echo "off"; fi
}

summary_print() {
  local service backups
  service=on
  [ "${NO_SERVICE:-false}" != true ] || service=off
  backups="$(_summary_onoff "${ANSWERS[backups]-true}")"
  [ "${NO_BACKUP:-false}" != true ] || backups=off

  echo
  echo "Here is what will be set up:"
  printf '  %-20s %s\n' "Server name:" "${ANSWERS[INSTANCE_NAME]-}"
  printf '  %-20s %s\n' "Server type:" "$(_summary_server_type)"
  if [ "${ANSWERS[server_kind]-fabric}" != modpack ]; then
    printf '  %-20s %s\n' "Minecraft version:" "${ANSWERS[JAVA.SERVER.VANILLA.VERSION]-latest}"
  fi
  printf '  %-20s %s MB\n' "Memory:" "${CHOSEN_HEAP_MB-}"
  printf '  %-20s %s\n' "Port:" "${CHOSEN_SERVER_PORT-}"
  printf '  %-20s %s\n' "Mod groups:" "$(_summary_mod_groups)"
  printf '  %-20s %s\n' "Start at boot:" "$service"
  printf '  %-20s %s\n' "Backups:" "$backups"
  printf '  %-20s %s\n' "Scheduled restarts:" "$(_summary_onoff "${ANSWERS[RESTART_SCHEDULE.ENABLED]-false}")"
  printf '  %-20s %s\n' "Management API:" "$(_summary_onoff "${ANSWERS[API_SERVER.ENABLED]-false}")"
  if [ "${ANSWERS[MIRROR.ENABLED]-false}" = true ]; then
    printf '  %-20s %s\n' "Creative mirror:" "${ANSWERS[MIRROR.ROLE]-target}"
  fi

  if [ "$(corrections_count)" -gt 0 ]; then
    echo
    echo "Things that were changed or need your attention:"
    corrections_render
  fi
  echo
}

# Like ask_yes_no, but a failed read (end of input) is a no.
_summary_confirm() { # question
  local answer=""
  while true; do
    read -r -p "$1 [Y/n]: " answer || { echo; return 1; }
    case "$answer" in
      [Yy]* | "") return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

summary_render() {
  summary_print

  if ! ui_is_interactive && [ "${EULA:-false}" = true ]; then
    return 0
  fi
  _summary_confirm "Continue with this setup?"
}

eula_confirm() {
  echo
  echo "Running a Minecraft server requires accepting the Minecraft EULA:"
  echo "  $EULA_URL"
  if [ "${EULA:-false}" = true ]; then
    echo "The EULA was accepted with --agree-eula."
    return 0
  fi
  local answer=""
  printf "Do you accept the Minecraft EULA? [y/N]: "
  read -r answer || { echo; return 1; }
  case "${answer,,}" in
    y | yes) return 0 ;;
    *) return 1 ;;
  esac
}

final_screen() {
  local name="${ANSWERS[INSTANCE_NAME]-}" port="${CHOSEN_SERVER_PORT:-25565}" ip backups_path
  ip="$(detect_local_ip || true)"

  echo
  echo "Your server is set up."
  echo "  Location: $HOME/${WIZARD_TARGET_DIR_NAME:-minecraft-server}/instances/$name"
  echo
  echo "How to join:"
  if [ -n "$ip" ]; then
    echo "  On the same network: use the address $ip and port $port."
  else
    echo "  On the same network: use this machine's local address and port $port."
  fi
  echo "  Friends elsewhere: the router must forward TCP port $port to this machine, and they"
  echo "  need your public address or a dynamic-DNS name. This tool did not configure the router."
  echo "  To check, look up \"port forwarding\" in your router's settings, then test the public"
  echo "  address from outside your home network."

  echo
  echo "Where things live:"
  if [ "${NO_BACKUP:-false}" = true ] || [ "${ANSWERS[backups]-true}" = false ]; then
    echo "  Backups: switched off."
  else
    backups_path="${ANSWERS[BACKUPS.BACKUPS_PATH]-}"
    if [ -z "$backups_path" ] || [ "$backups_path" = none ]; then
      backups_path="$HOME/${WIZARD_TARGET_DIR_NAME:-minecraft-server}/backups/$name"
    fi
    echo "  Backups: $backups_path"
  fi
  if [ "${NO_SERVICE:-false}" = true ]; then
    echo "  Service: none was created, so start the server by hand."
  else
    echo "  Service: the server runs as the systemd service \"$name\"; check it with: sudo systemctl status $name"
  fi

  if [ "$(corrections_count)" -gt 0 ]; then
    echo
    echo "Changes made for you during setup:"
    corrections_render
  fi
}

_FAILURE_NOTE_PRINTED=false

failure_screen() {
  [ "$_FAILURE_NOTE_PRINTED" != true ] || return 0
  case "${ROUTE:-}" in default | guided) ;; *) return 0 ;; esac
  [ -f "${SCRIPT_DIR:-.}/variables.json" ] || return 0
  _FAILURE_NOTE_PRINTED=true
  echo "Your answers are saved in variables.json. Run again to retry, or delete it to start over."
}
