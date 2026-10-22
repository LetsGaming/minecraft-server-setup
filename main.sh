#!/bin/bash
set -e

# Source modular scripts
source "$(dirname "$0")/src/common/checks.sh"
source "$(dirname "$0")/src/common/env.sh"
source "$(dirname "$0")/src/common/logging.sh"
source "$(dirname "$0")/src/common/args.sh"
source "$(dirname "$0")/src/common/prompts.sh"
source "$(dirname "$0")/src/common/flags.sh"
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
  ["--vanilla"]="VANILLA=false|Set up a vanilla/Fabric server instead of a modpack"
  ["--default"]="DEFAULT_ROUTE=false|Quick setup with safe defaults and almost no questions"
  ["--guided"]="GUIDED_ROUTE=false|Guided setup wizard with explanations for each choice"
  ["--allow-nodesource"]="ALLOW_NODESOURCE=false|Allow adding the NodeSource apt repository when Node.js is too old"
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
run_server_cleanup
maybe_start_server

if [ "$ROUTE" != power ]; then
  final_screen
fi
