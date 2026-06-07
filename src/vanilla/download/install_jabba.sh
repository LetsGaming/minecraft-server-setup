#!/usr/bin/env bash

set -e

# Define version if not already set
JABBA_VERSION="${JABBA_VERSION:-0.14.0}"
export JABBA_HOME="$HOME/.jabba"
export PATH="$JABBA_HOME/bin:$PATH"

# Check if jabba is installed
if command -v jabba &> /dev/null; then
  echo "Jabba is already installed."
else
  echo "Jabba not found. Installing Jabba v$JABBA_VERSION..."
  curl -sL https://github.com/Jabba-Team/jabba/raw/main/install.sh | bash
fi

# Source Jabba into the shell if not already available
if [ -f "$JABBA_HOME/jabba.sh" ]; then
  . "$JABBA_HOME/jabba.sh"
  export PATH="$JABBA_HOME/bin:$PATH"
  echo "Jabba sourced."
else
  echo "Jabba not found. Aborting."
  exit 1
fi
