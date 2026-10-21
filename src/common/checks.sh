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

check_platform() {
  local missing="" id id_like
  command -v apt-get > /dev/null 2>&1 || missing="${missing:+$missing, }the apt package manager (apt-get)"
  [ -d "${MC_SETUP_SYSTEMD_DIR:-/run/systemd/system}" ] || missing="${missing:+$missing, }systemd"
  id="$(detect_os_id)"
  id_like="$(detect_os_id_like)"
  case " ${id,,} ${id_like,,} " in
    *debian* | *ubuntu*) ;;
    *) missing="${missing:+$missing, }a Debian-family operating system (found: ${id:-unknown})" ;;
  esac
  if [ -n "$missing" ]; then
    echo "[ERROR] This computer is missing: $missing."
    echo "This tool supports Debian and Ubuntu with systemd. Nothing was changed."
    exit 1
  fi
}
