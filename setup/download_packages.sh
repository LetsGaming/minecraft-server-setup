#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install sudo if not installed
if ! command_exists sudo; then
    echo "Installing sudo..."
    apt install -y sudo
else
    echo "sudo is already installed."
fi

# Update package list
echo "Updating package list..."
sudo apt update

# Update all packages
echo "Updating all installed packages..."
sudo apt upgrade -y

# Install screen if not installed
if ! command_exists screen; then
    echo "Installing screen..."
    sudo apt install -y screen
else
    echo "screen is already installed."
fi

# Install node if not installed
if ! command_exists unzip; then
    echo "Installing node..."
    sudo apt install -y unzip
else
    echo "unzip is already installed."
fi

# Install node if not installed
if ! command_exists node; then
    echo "Installing node..."
    sudo apt install -y nodejs
    sudo apt install -y npm
else
    echo "node is already installed."
fi

echo "All packages installed."
