#!/bin/bash
set -e

# Source modular scripts
source "$(dirname "$0")/src/common/checks.sh"
source "$(dirname "$0")/src/common/env.sh"
source "$(dirname "$0")/src/common/logging.sh"
source "$(dirname "$0")/src/common/args.sh"
source "$(dirname "$0")/src/common/prompts.sh"
source "$(dirname "$0")/src/common/flags.sh"
source "$(dirname "$0")/src/common/mirror_flags.sh"
source "$(dirname "$0")/src/common/setup.sh"
source "$(dirname "$0")/src/common/ui.sh"
source "$(dirname "$0")/src/common/prereqs.sh"
source "$(dirname "$0")/src/common/corrections.sh"
source "$(dirname "$0")/src/common/detect.sh"
source "$(dirname "$0")/src/wizard/validators.sh"
source "$(dirname "$0")/src/wizard/whiptail.sh"
source "$(dirname "$0")/src/wizard/manifest.sh"
source "$(dirname "$0")/src/wizard/engine.sh"
source "$(dirname "$0")/src/wizard/config_writer.sh"
source "$(dirname "$0")/src/wizard/safety.sh"
source "$(dirname "$0")/src/wizard/summary.sh"
source "$(dirname "$0")/src/wizard/route.sh"

# Define available flags
declare -A ARG_OPTS=(
  ["--no-start"]="NO_START=false|Do not start the server"
  ["--agree-eula"]="EULA=false|Accept the EULA"
  ["--no-service"]="NO_SERVICE=false|Skip creating the systemd service"
  ["--no-backup"]="NO_BACKUP=false|Skip creating the backup job"
  ["--api-server"]="SETUP_API_SERVER=false|Set up the minecraft-bot API wrapper service"
  ["--dry-run"]="DRY_RUN=false|Only print what would be done"
  ["--verbose"]="VERBOSE=false|Print additional logging info"
  ["--y"]="ACCEPT_ALL=false|Accept all defaults and skip prompts"
  ["--check"]="CHECK_ONLY=false|Validate config and environment without running setup"
  ["--modpack"]="MODPACK=false|Set up a CurseForge modpack server instead of a vanilla/Fabric server"
  ["--mirror-source"]="MIRROR_SOURCE=false|Also set this server up as the survival side of the optional creative mirror"
  ["--mirror-target"]="MIRROR_TARGET=false|Also prepare this server as the creative side of the optional creative mirror (with --default or --guided it needs --mirror-remote and --mirror-seed, or asks for them)"
  ["--mirror-no-permissions"]="MIRROR_NO_PERMISSIONS=false|With --mirror-target: do not install LuckPerms (by default every player may use /gamemode)"
  ["--default"]="DEFAULT_ROUTE=false|Quick setup with safe defaults and almost no questions"
  ["--guided"]="GUIDED_ROUTE=false|Guided setup wizard with explanations for each choice"
  ["--allow-nodesource"]="ALLOW_NODESOURCE=false|Allow adding the NodeSource apt repository when Node.js is too old"
)

declare -A ARG_VALUE_OPTS=(
  ["--mirror-remote"]="MIRROR_REMOTE|Survival server for --mirror-target: host or IP (optionally mcsync@host)"
  ["--mirror-seed"]="MIRROR_SEED|Seed of the survival world for --mirror-target (its level-seed)"
  ["--instance-name"]="INSTANCE_NAME_FLAG|Name of the server instance on the Default route (default: server)"
)

# Run lifecycle
check_root
require_sudo
set_environment

parse_args "$@"
export ALLOW_NODESOURCE DRY_RUN SCRIPT_DIR

# Check-only mode: validate and exit
if [ "$CHECK_ONLY" = true ]; then
  ensure_variables_json
  run_preflight_check
  exit $?
fi

check_platform
select_route
if [ -n "$INSTANCE_NAME_FLAG" ] && ! validate_instance_name "$INSTANCE_NAME_FLAG" > /dev/null; then
  ui_notice error "--instance-name may only contain letters, numbers, hyphens and underscores. Nothing was changed." >&2
  exit 1
fi
mirror_flags_check

# Nothing below may call node before the prerequisite stage has made it available.
if [ "$ROUTE" = power ]; then
  ensure_variables_json
  ensure_prerequisites power
else
  ensure_prerequisites "$ROUTE"
fi
# download_packages.sh runs later as a subprocess; this makes its own call a no-op.
export PREREQS_DONE

if [ "$ROUTE" != power ]; then
  run_wizard "$ROUTE"
fi

if [ "$ROUTE" = power ]; then
  set_flags_from_defaults "$@"
  prompt_for_flags
fi

mirror_flags_apply

# Arm the rollback trap now that we are about to make real changes.
_SETUP_SUCCESS=false
# Record what exists before the first change, so a failure removes only what
# this run created (S-001). Skipped in a dry run, which changes nothing.
if [[ "$DRY_RUN" != true ]]; then snapshot_setup_state; fi
_rollback_if_needed() {
  if [[ "$_SETUP_SUCCESS" != true && "$DRY_RUN" != true ]]; then
    run_rollback
    failure_screen
  fi
}
trap '_rollback_if_needed' EXIT
trap '_rollback_if_needed; exit 130' INT

run_server_setup
run_post_mod_config
run_optional_setup
# Mark success before cleanup/start so those failures don't trigger rollback
_SETUP_SUCCESS=true
# Optional and after the success mark: a mirror problem never rolls the install back.
run_mirror_setup
run_server_cleanup
maybe_start_server

if [ "$ROUTE" != power ]; then
  final_screen
fi
