#!/usr/bin/env bash

# Check if jabba is installed
if command -v jabba &> /dev/null; then
  echo "Jabba is already installed."
else
  echo "Jabba not found. Installing Jabba v$JABBA_VERSION..."

  # Install Jabba
  curl -sL https://github.com/shyiko/jabba/raw/master/install.sh | bash

  # Source Jabba into current shell (assuming default install path)
  if [ -f "$HOME/.jabba/jabba.sh" ]; then
    . "$HOME/.jabba/jabba.sh"
    echo "Jabba installed and sourced."
  else
    echo "Jabba installation script not found. Aborting."
    exit 1
  fi
fi
