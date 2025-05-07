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

    run_or_echo "bash \"$SCRIPT_DIR/setup/download/download_packages.sh\""
    export JABBA_VERSION=...
    curl -sL https://github.com/shyiko/jabba/raw/master/install.sh | bash && . ~/.jabba/jabba.sh

    
else
    warn "This script is not yet implemented"
fi