#!/bin/bash

# Exit on error
set -e

# Ensure required variables are defined
: "${TARGET_DIR_NAME:?Missing TARGET_DIR_NAME in variables.txt}"
: "${MODPACK_NAME:?Missing MODPACK_NAME}"

BASE_DIR="$HOME/$TARGET_DIR_NAME"
MODPACK_DIR="$BASE_DIR/$MODPACK_NAME"
SCRIPTS_DIR="$BASE_DIR/scripts/$MODPACK_NAME"

# Create base directory and modpack directory
mkdir -p "$BASE_DIR"
MODPACK_DIR="$BASE_DIR/$MODPACK_NAME"
mkdir -p "$MODPACK_DIR"

# Create scripts directories
SCRIPTS_DIR="$BASE_DIR/scripts/$MODPACK_NAME"
mkdir -p "$SCRIPTS_DIR"
