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

WIZARD_TARGET_DIR_NAME=""

_wizard_target_dir_name() {
  WIZARD_TARGET_DIR_NAME="$(jq -r '.TARGET_DIR_NAME // "minecraft-server"' "$SCRIPT_DIR/variables.example.json" | tr -d '\r')"
}

_wizard_guard_config() {
  if [ -e "$SCRIPT_DIR/variables.json" ] || [ -L "$SCRIPT_DIR/variables.json" ]; then
    ui_notice error "variables.json already exists; delete it or rename it to run the setup again, or run without --default/--guided to use it." >&2
    exit 1
  fi
}

_wizard_nothing_changed() {
  echo "Nothing was changed."
  exit 0
}

# Prints the resolver's JSON, or exits 1 without having changed anything.
_wizard_resolve_version() {
  local out
  if ! out="$(node "$SCRIPT_DIR/src/setup/download/resolve_default_version.js" 2>/dev/null)" || ! jq -e '.minecraft' <<< "$out" > /dev/null 2>&1; then
    ui_notice error "Could not check which Minecraft version works with the default mods; check your internet connection and run again." >&2
    exit 1
  fi
  printf '%s' "$out"
}

wizard_apply_flags() {
  [ "${NO_START:-false}" = true ] || NO_START=false
  [ "${NO_SERVICE:-false}" = true ] || NO_SERVICE=false
  if [ "${NO_BACKUP:-false}" != true ]; then
    if [ "${ANSWERS[backups]-true}" = false ]; then NO_BACKUP=true; else NO_BACKUP=false; fi
  fi
  if [ "${SETUP_API_SERVER:-false}" != true ]; then
    if [ "${ANSWERS[API_SERVER.ENABLED]-false}" = true ]; then SETUP_API_SERVER=true; else SETUP_API_SERVER=false; fi
  fi
  EULA=true
  ACCEPT_ALL=true
  case "${ANSWERS[server_kind]-fabric}" in
    modpack) VANILLA=false ;;
    *) VANILLA=true ;;
  esac
  export NO_START NO_SERVICE NO_BACKUP SETUP_API_SERVER EULA ACCEPT_ALL VANILLA
}

# Summary, EULA, then write variables.json and set the install flags.
_wizard_confirm_and_write() {
  local wrote_curseforge=false
  summary_render || _wizard_nothing_changed
  eula_confirm || _wizard_nothing_changed
  if [ "${DRY_RUN:-false}" = true ]; then
    echo "Dry run: nothing was written or installed."
    summary_print
    exit 0
  fi
  _wizard_guard_config
  if [ -n "${ANSWERS[curseforge_pack]-}" ] || [ -n "${ANSWERS[curseforge_key]-}" ]; then
    config_write_curseforge "$SCRIPT_DIR/src/setup/download/json/curseforge_variables.json" || exit 1
    wrote_curseforge=true
  fi
  if ! config_write "$SCRIPT_DIR/variables.json"; then
    if [ "$wrote_curseforge" = true ]; then
      rm -f "$SCRIPT_DIR/src/setup/download/json/curseforge_variables.json"
    fi
    exit 1
  fi
  wizard_apply_flags
}

run_default_route() {
  local resolved minecraft dropped notice
  local -a notices=()
  _wizard_guard_config
  _wizard_target_dir_name
  resolved="$(_wizard_resolve_version)"
  minecraft="$(jq -r '.minecraft' <<< "$resolved" | tr -d '\r')"
  dropped="$(jq -r '(.dropped // []) | join(",")' <<< "$resolved" | tr -d '\r')"
  mapfile -t notices < <(jq -r '(.notices // [])[] | if type == "object" then .text else . end' <<< "$resolved" | tr -d '\r')

  corrections_reset
  declare -gA ANSWERS=()
  for notice in "${notices[@]}"; do
    correction_add adjusted "Minecraft version" "latest" "$minecraft" "$notice"
  done
  choose_instance_name server "$WIZARD_TARGET_DIR_NAME"
  choose_server_port
  choose_heap ""

  ANSWERS[INSTANCE_NAME]="$CHOSEN_INSTANCE_NAME"
  ANSWERS[server_kind]=fabric
  ANSWERS[JAVA.SERVER.VANILLA.VERSION]="$minecraft"
  ANSWERS[memory]="$(heap_to_java_size "$CHOSEN_HEAP_MB")"
  ANSWERS[JAVA.JAVA_ARGS_CONFIG.g1gc.alwaysPreTouch]="$(heap_pretouch "$CHOSEN_HEAP_MB")"
  ANSWERS[backups]=true
  if [ "$CHOSEN_SERVER_PORT" != "$DEFAULT_SERVER_PORT" ]; then
    ANSWERS[JAVA.SERVER.PORT]="$CHOSEN_SERVER_PORT"
  fi
  if [ -n "$dropped" ]; then
    ANSWERS[JAVA.SERVER.VANILLA.MODS.EXCLUDE]="$dropped"
  fi

  _wizard_confirm_and_write
}

# Prints the megabytes for a size such as 4G or 2048M, or nothing when it is not one.
_wizard_size_to_mb() { # size
  [[ "$1" =~ ^[0-9]{1,6}[GgMm]$ ]] || return 0
  case "$1" in
    *[Gg]) echo $(( 10#${1%?} * 1024 )) ;;
    *) echo $(( 10#${1%?} )) ;;
  esac
}

# A value that is not a size is passed on as typed so choose_heap records the correction.
_wizard_choose_heap_for() { # size
  local mb
  mb="$(_wizard_size_to_mb "$1")"
  [ -n "$mb" ] || mb="$1"
  choose_heap "$mb"
}

run_guided_route() {
  local rc=0
  _wizard_guard_config
  if ! engine_available; then
    ui_notice info "The guided screens cannot be shown in this terminal, so the quick setup is used instead."
    run_default_route
    return 0
  fi
  corrections_reset
  engine_run guided || rc=$?
  case "$rc" in
    0) ;;
    11) _wizard_nothing_changed ;;
    12)
      ui_notice info "The guided screens stopped working, so the quick setup is used instead."
      run_default_route
      return 0
      ;;
    *) exit 1 ;;
  esac

  _wizard_target_dir_name
  choose_instance_name "${ANSWERS[INSTANCE_NAME]:-server}" "$WIZARD_TARGET_DIR_NAME"
  _wizard_choose_heap_for "${ANSWERS[memory]:-}"
  choose_server_port
  ANSWERS[INSTANCE_NAME]="$CHOSEN_INSTANCE_NAME"
  ANSWERS[memory]="$(heap_to_java_size "$CHOSEN_HEAP_MB")"
  ANSWERS[JAVA.JAVA_ARGS_CONFIG.g1gc.alwaysPreTouch]="$(heap_pretouch "$CHOSEN_HEAP_MB")"
  if [ "$CHOSEN_SERVER_PORT" != "$DEFAULT_SERVER_PORT" ]; then
    ANSWERS[JAVA.SERVER.PORT]="$CHOSEN_SERVER_PORT"
  fi

  _wizard_confirm_and_write
}

run_wizard() { # route
  case "$1" in
    default) run_default_route ;;
    guided) run_guided_route ;;
    *) echo "Unknown setup route: $1" >&2; exit 1 ;;
  esac
}
