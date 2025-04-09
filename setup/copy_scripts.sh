#!/bin/bash

# Exit on error
set -e

# Ensure required variables are defined
: "${SCRIPT_DIR:?Missing SCRIPT_DIR}"
: "${SCRIPTS_DIR:?Missing SCRIPTS_DIR}"

# Copy scripts into the target directory
cp -r "$SCRIPT_DIR/scripts/"* "$SCRIPTS_DIR/"
