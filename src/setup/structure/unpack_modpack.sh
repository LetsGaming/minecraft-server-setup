#!/bin/bash
set -e

# Replaces unpack_modpack.js — extracts the downloaded server pack into the
# instance dir and moves any separately-downloaded mods into place. Uses the
# system `unzip` (installed by download_packages.sh), which lets us drop the
# `unzipper` npm dependency entirely.

: "${SCRIPT_DIR:?SCRIPT_DIR not set}"
: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

TEMP_DIR="$SCRIPT_DIR/src/setup/download/temp"
MODPACK_SOURCE="$TEMP_DIR/server-pack.zip"
MODS_SOURCE="$TEMP_DIR/mods"

INSTANCE_DIR="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME"
MODS_DIR="$INSTANCE_DIR/mods"

if [ ! -f "$MODPACK_SOURCE" ]; then
  echo "Modpack archive $MODPACK_SOURCE not found." >&2
  exit 1
fi

mkdir -p "$INSTANCE_DIR"
unzip -o -q "$MODPACK_SOURCE" -d "$INSTANCE_DIR"
echo "Modpack unpacked successfully."

if [ -d "$MODS_SOURCE" ]; then
  mkdir -p "$MODS_DIR"
  shopt -s dotglob nullglob
  for f in "$MODS_SOURCE"/*; do
    mv "$f" "$MODS_DIR/"
    echo "Moved $(basename "$f") to $MODS_DIR"
  done
  shopt -u dotglob nullglob
else
  echo "Mods directory $MODS_SOURCE not found." >&2
fi
