#!/bin/bash
set -e

# Source modular scripts
source "$(dirname "$0")/common/checks.sh"
source "$(dirname "$0")/common/env.sh"
source "$(dirname "$0")/common/logging.sh"
source "$(dirname "$0")/common/args.sh"
source "$(dirname "$0")/common/prompts.sh"

# Define available flags
declare -A ARG_OPTS=(
    ["--testing"]="TESTING=false|Run in Testing mode"
)

check_root
require_sudo
set_environment

# Parse command line arguments
parse_args "$@"

if [[ "$TESTING" == "true" ]]; then
    # Run the testing setup
    echo "Running in testing mode..."
    # TODO: Implement vanilla setup
else
    warn "This script is not yet implemented"
fi