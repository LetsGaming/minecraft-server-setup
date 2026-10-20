#!/bin/bash
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a package if its command is missing
install_if_missing() {
    local cmd="$1"
    local pkg="$2"

    if ! command_exists "$cmd"; then
        echo "Installing $pkg..."
        sudo apt install -y "$pkg"
    else
        echo "$pkg is already installed."
    fi
}

# Install sudo if needed (before we use it)
if ! command_exists sudo; then
    echo "Installing sudo..."
    apt install -y sudo
else
    echo "sudo is already installed."
fi

# Update package list
echo "Updating package list..."
sudo apt update

# Upgrading every system package is the admin's call, not a side effect of
# setting up one server (S-027): opt in with MC_SETUP_UPGRADE_SYSTEM=true.
if [[ "${MC_SETUP_UPGRADE_SYSTEM:-false}" == "true" ]]; then
    echo "Upgrading all installed packages (MC_SETUP_UPGRADE_SYSTEM=true)..."
    sudo apt upgrade -y
fi

# Install required packages
install_if_missing curl curl 
install_if_missing screen screen
install_if_missing unzip unzip
install_if_missing node nodejs
install_if_missing npm npm
install_if_missing cron cron
install_if_missing jq jq
install_if_missing rsync rsync
install_if_missing zstd zstd
# setfacl: the wrapper's service user gets its access through ACLs
# (service_user.sh stops without it).
install_if_missing setfacl acl

# Check if cron service is running
if sudo systemctl is-active --quiet cron; then
    echo "cron service is running."
else
    echo "cron service is not running. Starting it now..."
    sudo systemctl start cron
    sudo systemctl enable cron
fi

# Install Node.js dependencies
echo "Installing Node.js packages..."
cd "$SCRIPT_DIR"
# From the committed lockfile (S-027): every install gets the same axios and
# semver the suite was tested with, not whatever the range resolves to today.
npm ci --omit=dev

echo "All packages installed and up to date."
