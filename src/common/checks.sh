#!/bin/bash
set -e

check_root() {
  if [ "$(id -u)" -eq 0 ]; then
    echo "[ERROR] Do not run this script as root."
    echo "Try: sudo -u <username> bash main.sh"
    exit 1
  fi
}

require_sudo() {
  if ! sudo -v; then
    echo "[ERROR] This script requires sudo privileges."
    exit 1
  fi
}
