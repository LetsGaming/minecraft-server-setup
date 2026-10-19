#!/bin/bash
# The target instance: validation, derived paths, and the state the later phases share.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# Checks the scripts directory argument and loads its variables.txt.
# Sets TARGET_SCRIPTS_DIR, VARS_FILE and BASE_DIR.
validate_target() {
  [[ -z "$TARGET_SCRIPTS_DIR" ]] && { err "Missing required argument."; echo; print_help; exit 1; }

  TARGET_SCRIPTS_DIR="$(cd "$TARGET_SCRIPTS_DIR" 2>/dev/null && pwd)" || {
    err "Directory does not exist: $TARGET_SCRIPTS_DIR"; exit 1; }

  VARS_FILE="$TARGET_SCRIPTS_DIR/common/variables.txt"
  [[ ! -f "$VARS_FILE" ]] && {
    err "Not a valid scripts directory: common/variables.txt not found."
    info "Expected: $VARS_FILE"
    info "Point to the deployed instance dir, e.g.: /home/mc/minecraft-server/scripts/survival"
    exit 1; }

  [[ ! -d "$NEW_SCRIPTS_SOURCE" ]] && {
    err "New scripts source not found: $NEW_SCRIPTS_SOURCE"
    info "Run this script from the minecraft-server-setup project root."
    exit 1; }

  source "$VARS_FILE"

  # BASE_DIR is the install root — derived from the scripts directory path so it
  # works correctly for both old (<target>/<instance>/) and new
  # (<target>/instances/<instance>/) directory structures.
  # TARGET_SCRIPTS_DIR = <install-root>/scripts/<instance>
  BASE_DIR="$(dirname "$(dirname "$TARGET_SCRIPTS_DIR")")"

  # Validate SERVER_PATH is present (used later for structure-detection)
  [[ -z "${SERVER_PATH:-}" ]] && {
    err "SERVER_PATH not set in variables.txt"
    exit 1
  }
  return 0
}

# Tells the server-side migrations (server_migrations.sh) where everything is.
init_server_migration_inputs() {
  SM_SOURCE_ROOT="$MIGRATE_SCRIPT_DIR"
  SM_INSTANCE_NAME="${INSTANCE_NAME:-}"
  SM_SCRIPTS_DIR="$TARGET_SCRIPTS_DIR"
  SM_INSTANCE_DIR="$SERVER_PATH"
  SM_DRY_RUN=$DRY_RUN
  return 0
}

# The API wrapper is the one shared service. It is installed from its pinned
# release (install_api_server.js), not synced from this checkout.
init_api_state() {
  API_INSTALLER="$MIGRATE_SCRIPT_DIR/src/setup/management/install_api_server.js"
  API_DIR="$BASE_DIR/services/api-server"
  API_SVC="$(basename "$BASE_DIR")-api-server.service"
  NEEDS_API_UPDATE=false
  API_UPDATE_FAILED=false
  API_FROM=""; API_TO=""
  SM_MIGRATIONS_OK=true
  return 0
}

print_banner() {
  echo
  echo -e "${BOLD}Minecraft Server Setup — Migration${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  info "Instance:     ${INSTANCE_NAME:-unknown}"
  info "Server path:  ${SERVER_PATH:-unknown}"
  info "Install root: $BASE_DIR"
  info "Scripts dir:  $TARGET_SCRIPTS_DIR"
  info "Source (new): $NEW_SCRIPTS_SOURCE"
  echo
  return 0
}
