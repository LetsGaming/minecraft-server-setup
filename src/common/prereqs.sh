#!/bin/bash
set -e

NODE_MIN_MAJOR=18
NODESOURCE_SETUP_URL="https://deb.nodesource.com/setup_22.x"

declare -gA PREREQ_COMMANDS=(
  [curl]=curl
  [screen]=screen
  [unzip]=unzip
  [cron]=cron
  [jq]=jq
  [rsync]=rsync
  [zstd]=zstd
  [setfacl]=acl
  [node]=nodejs
  [npm]=npm
)
# Associative arrays have no stable order; this keeps install order and output deterministic.
PREREQ_ORDER=(curl screen unzip cron jq rsync zstd setfacl node npm)

_prereq_run() {
  if declare -F run_or_echo > /dev/null; then
    run_or_echo "$1"
  elif [ "${DRY_RUN:-false}" = true ]; then
    echo "[DRY-RUN] $1"
  else
    eval "$1"
  fi
}

prereqs_missing() { # route: default|guided|power
  local cmd
  for cmd in "${PREREQ_ORDER[@]}"; do
    command -v "$cmd" > /dev/null 2>&1 || echo "${PREREQ_COMMANDS[$cmd]}"
  done
  if [ "${1:-default}" = guided ] && ! command -v whiptail > /dev/null 2>&1; then
    echo whiptail
  fi
}

node_major() {
  local version
  version="$(node -v 2> /dev/null)" || return 0
  version="${version#v}"
  [[ "$version" =~ ^[0-9]+ ]] && echo "${BASH_REMATCH[0]}"
  return 0
}

distro_node_major() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*Candidate:[[:space:]]*([0-9]+:)?([0-9]+) ]]; then
      echo "${BASH_REMATCH[2]}"
      return 0
    fi
  done < <(apt-cache policy nodejs 2> /dev/null || true)
  return 0
}

node_install_action() {
  local installed candidate
  installed="$(node_major)"
  if [ -n "$installed" ] && [ "$installed" -ge "$NODE_MIN_MAJOR" ]; then
    echo ok
    return 0
  fi
  candidate="$(distro_node_major)"
  if [ -n "$candidate" ] && [ "$candidate" -ge "$NODE_MIN_MAJOR" ]; then
    echo distro
  else
    echo nodesource
  fi
}

_print_nodesource_refusal() {
  {
    echo "Node.js $NODE_MIN_MAJOR or newer is required, and this system's own package is too old."
    echo "Installing Node 22 adds the third-party NodeSource apt repository. To allow that, run"
    echo "the setup again with --allow-nodesource, or install Node yourself with:"
    echo ""
    echo "  curl -fsSL $NODESOURCE_SETUP_URL -o nodesource_setup.sh"
    echo "  sudo -E bash nodesource_setup.sh"
    echo "  sudo apt install -y nodejs"
  } >&2
}

_install_node_from_nodesource() {
  local script rc=0
  script="$(mktemp)"
  {
    _prereq_run "curl -fsSL $NODESOURCE_SETUP_URL -o \"$script\"" &&
      _prereq_run "sudo -E bash \"$script\"" &&
      _prereq_run "sudo apt install -y nodejs"
  } || rc=$?
  rm -f "$script"
  return "$rc"
}

ensure_prerequisites() { # route
  [ "${PREREQS_DONE:-0}" = 1 ] && return 0
  local route="${1:-default}" action pkg
  local -a missing=()

  if ! command -v sudo > /dev/null 2>&1; then
    echo "Installing sudo..."
    _prereq_run "apt install -y sudo"
  fi

  echo "Updating package list..."
  _prereq_run "sudo apt update"

  if [ "${MC_SETUP_UPGRADE_SYSTEM:-false}" = true ]; then
    echo "Upgrading all installed packages (MC_SETUP_UPGRADE_SYSTEM=true)..."
    _prereq_run "sudo apt upgrade -y"
  fi

  action="$(node_install_action)"
  if [ "$action" = nodesource ] && [ "${ALLOW_NODESOURCE:-false}" != true ]; then
    _print_nodesource_refusal
    exit 1
  fi

  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if [ "$action" != ok ] && { [ "$pkg" = nodejs ] || [ "$pkg" = npm ]; }; then
      continue
    fi
    missing+=("$pkg")
  done < <(prereqs_missing "$route")

  for pkg in "${missing[@]}"; do
    echo "Installing $pkg..."
    _prereq_run "sudo apt install -y $pkg"
  done

  case "$action" in
    distro)
      echo "Installing Node.js and npm..."
      _prereq_run "sudo apt install -y nodejs npm"
      ;;
    nodesource)
      echo "Installing Node.js 22 from the NodeSource repository..."
      _install_node_from_nodesource || return 1
      command -v npm > /dev/null 2>&1 || _prereq_run "sudo apt install -y npm"
      ;;
  esac

  if sudo systemctl is-active --quiet cron; then
    echo "cron service is running."
  else
    echo "cron service is not running. Starting it now..."
    _prereq_run "sudo systemctl start cron"
    _prereq_run "sudo systemctl enable cron"
  fi

  echo "Installing Node.js packages..."
  _prereq_run "cd \"${SCRIPT_DIR:-.}\" && npm ci --omit=dev"

  PREREQS_DONE=1
  echo "All packages installed and up to date."
}
