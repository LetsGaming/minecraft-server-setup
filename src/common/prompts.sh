#!/bin/bash
set -e

ask_yes_no() {
  while true; do
    read -r -p "$1 [Y/n]: " yn || { echo; return 1; }
    case $yn in
      [Yy]*|"") return 0 ;;
      [Nn]*) return 1 ;;
      * ) echo "Please answer yes or no." ;;
    esac
  done
}
