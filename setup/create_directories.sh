#!/bin/bash

# Exit on error
set -e

# Ensure required variables are defined
: "${BASE_DIR:?Missing BASE_DIR}"
: "${MODPACK_NAME:?Missing MODPACK_NAME}"

# Create base directory and modpack directory
mkdir -p "$BASE_DIR"
MODPACK_DIR="$BASE_DIR/$MODPACK_NAME"
mkdir -p "$MODPACK_DIR"

# Create scripts directories
SCRIPTS_DIR="$BASE_DIR/scripts/$MODPACK_NAME"
mkdir -p "$SCRIPTS_DIR"
