# Minecraft Server Setup

A collection of scripts and utilities to automate the setup and configuration of a Minecraft server. This project provides a streamlined process to launch, update, and manage your Minecraft server environment using shell scripts and Node.js tools.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Folder Structure](#folder-structure)
- [Contributing](#contributing)

## Overview

The **Minecraft Server Setup** project is designed for those who want a hassle-free way to deploy a Minecraft server. It leverages shell scripts (Bash) along with Node.js to automate tasks such as installing dependencies, configuring server settings, and initializing the server.

## Features

- **Automated Server Configuration:** Run a simple command to get your server up and running.
- **Script-Based Setup:** Contains shell scripts (e.g., `main.sh`) to handle installation and configuration tasks.
- **Node.js Utilities:** Utilizes `package.json` for managing dependencies and potentially running auxiliary scripts.
- **Customizable Environment:** Easily modify configuration files and setup scripts to suit your server’s needs.

## Prerequisites

Before you begin, ensure you have the following installed on your system:

- **Operating System:** Unix-like environment (Linux, macOS, or WSL for Windows)
- **Bash:** The scripts are written in Bash and require a compatible shell.

## Installation

1. **Clone the Repository:**

   ```bash
   git clone https://github.com/LetsGaming/minecraft-server-setup.git
   ```
   ```bash
   cd minecraft-server-setup
   ```

2. **Get API Key**

   - Navigate to [curseforge API](https://console.curseforge.com/#/api-keys) and generate a new API Key
   - Copy it for the next step

4. **Review and Customize Configurations:**

   - Change the variables in [variables.json](./setup/variables.json) to match your desired configuration
   - Set the pack_id and your api_key in [curseforge_variables.json](./setup/download/curseforge_variables.json)

## Usage

Once the above steps are completed, you can run the main setup script to start the server installation process:

```bash
sudo -u <username> bash main.sh
```

If you dont wish to automatically start the server:

```bash
bash main.sh --no-start
```

The `main.sh` script will automatically setup everything needed for the server and start it once finished.

## Folder Structure

- **main.sh:** The main shell script to initiate the server setup process.
- **package.json & package-lock.json:** Files used for managing Node.js dependencies.
- **setup/**: Contains configuration files or additional scripts required for initializing the server.
- **scripts/**: A directory for supporting shell scripts that perform various server management tasks.
- **.gitignore:** Specifies files and directories to be ignored by Git.

## Contributing

Contributions are welcome! If you have suggestions, bug fixes, or enhancements, please follow these steps:

1. Fork the repository.
2. Create a feature or bugfix branch.
3. Make your changes and commit them with clear descriptions.
4. Open a pull request detailing your changes.

For major changes, please open an issue first to discuss what you would like to change.
