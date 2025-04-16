#!/bin/bash

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

# Upgrade all packages
echo "Upgrading all installed packages..."
sudo apt upgrade -y

# Install required packages
install_if_missing screen screen
install_if_missing unzip unzip
install_if_missing node nodejs
install_if_missing npm npm
install_if_missing cron cron

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
npm install --no-package-lock --omit=dev

echo "All packages installed and up to date."
