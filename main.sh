#!/bin/bash
set -e

# Source modular scripts
source "$(dirname "$0")/common/checks.sh"
source "$(dirname "$0")/common/env.sh"
source "$(dirname "$0")/common/logging.sh"
source "$(dirname "$0")/common/args.sh"
source "$(dirname "$0")/common/prompts.sh"
source "$(dirname "$0")/common/flags.sh"
source "$(dirname "$0")/common/setup.sh"

# Define available flags
declare -A ARG_OPTS=(
  ["--no-start"]="NO_START=false|Do not start the server"
  ["--agree-eula"]="EULA=false|Accept the EULA"
  ["--no-service"]="NO_SERVICE=false|Skip creating the systemd service"
  ["--no-backup"]="NO_BACKUP=false|Skip creating the backup job"
  ["--api-server"]="SETUP_API_SERVER=false|Set up the minecraft-bot API wrapper service"
  ["--interface"]="SETUP_INTERFACE=false|Setup the web interface"
  ["--dry-run"]="DRY_RUN=false|Only print what would be done"
  ["--verbose"]="VERBOSE=false|Print additional logging info"
  ["--y"]="ACCEPT_ALL=false|Accept all defaults and skip prompts"
  ["--check"]="CHECK_ONLY=false|Validate config and environment without running setup"
)

# Run lifecycle
check_root
require_sudo
set_environment

parse_args "$@"

# Check-only mode: validate and exit
if [ "$CHECK_ONLY" = true ]; then
  run_preflight_check
  exit $?
fi

set_flags_from_defaults "$@"
prompt_for_flags
run_modpack_setup
run_optional_setup
run_modpack_cleanup
maybe_start_server
