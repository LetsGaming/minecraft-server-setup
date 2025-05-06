#!/bin/bash
set -e

log() { echo "[INFO] $1"; }
warn() { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; }

run_or_echo() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] $1"
  else
    eval "$1"
  fi
}

vlog() {
  if [ "$VERBOSE" = true ]; then
    log "$1"
  fi
}
