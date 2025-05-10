#!/usr/bin/env bash

set -e

# Define version if not already set
JABBA_VERSION="${JABBA_VERSION:-0.14.0}"

# Check if jabba is installed
if command -v jabba &> /dev/null; then
  echo "Jabba is already installed."
else
  echo "Jabba not found. Installing Jabba v$JABBA_VERSION..."

  # Install Jabba
  curl -sL https://github.com/Jabba-Team/jabba/raw/main/install.sh | bash

  # Source Jabba into current shell (assuming default install path)
  export JABBA_HOME="$HOME/.jabba"
  if [ -f "$JABBA_HOME/jabba.sh" ]; then
    . "$JABBA_HOME/jabba.sh"
    echo "Jabba installed and sourced."
  else
    echo "Jabba installation script not found. Aborting."
    exit 1
  fi
fi
