#!/bin/bash
set -e

# Replaces agree_eula.js — flips eula=<x> to eula=true in the instance's
# eula.txt, creating the file if the server jar hasn't generated it yet.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

EULA_FILE="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME/eula.txt"

mkdir -p "$(dirname "$EULA_FILE")"

if [ -f "$EULA_FILE" ] && grep -qi '^eula=' "$EULA_FILE"; then
  # Replace whatever the existing eula= line says with eula=true, preserving
  # any other lines (e.g. the comment line Mojang writes).
  sed -i 's/^[Ee][Uu][Ll][Aa]=.*/eula=true/' "$EULA_FILE"
else
  printf 'eula=true\n' >> "$EULA_FILE"
fi

echo "EULA has been set to true."
