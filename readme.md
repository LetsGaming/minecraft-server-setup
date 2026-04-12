# Minecraft Server Setup

A collection of scripts and utilities to automate the setup and configuration of a Minecraft server. This project provides a streamlined process to launch and manage your Minecraft server environment using shell scripts and Node.js tools.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Version Compatibility](#version-compatibility)
- [Folder Structure](#folder-structure)
- [Contributing](#contributing)

## Overview

The **Minecraft Server Setup** project is designed for those who want a hassle-free way to deploy a Minecraft server. It leverages shell scripts (Bash) along with Node.js to automate tasks such as installing dependencies, configuring server settings, and initializing the server.

## Features

- **Automated Server Configuration:** Run a single command to get your server up and running.
- **Dynamic Java Detection:** Automatically determines the correct Java version from Mojang's API — no hardcoded version maps to maintain.
- **Version-Agnostic:** Supports both legacy `1.x.y` versions and the new `YY.D.H` format (e.g. `26.1`, `26.2`).
- **Modpack & Vanilla Support:** Set up CurseForge modpack servers or vanilla/Fabric servers with optional performance mods.
- **Backup System:** Grandfather-father-son rotation with zstd compression, archive validation, and configurable retention.
- **Update System:** Check for mod updates, update server versions, and handle incompatible mods — all with automatic pre-update backups.
- **Maintenance Mode:** MOTD swap, non-admin kick monitoring, and automatic cleanup on exit.
- **Web Interface:** Optional Crafty Controller integration.
- **Dry Run:** Preview what any command would do before executing.

## Prerequisites

Before you begin, ensure you have the following installed on your system:

- **Operating System:** Unix-like environment (Linux, macOS, or WSL for Windows)
- **Bash:** Version 4.0+ (required for associative arrays)
- **Node.js:** Version 18+

## Installation

1. **Clone the Repository:**

   ```bash
   git clone https://github.com/LetsGaming/minecraft-server-setup.git
   cd minecraft-server-setup
   ```

2. **Install Dependencies:**

   ```bash
   npm install
   ```

3. **Get API Key and Pack ID** *(modpack setup only)*

   - Navigate to [CurseForge API](https://console.curseforge.com/#/api-keys) and generate a new API Key
   - Navigate to your desired Modpack and find the Pack ID on the right side
   - For further information read: [Readme](./setup/download/readme.md)

4. **Review and Customize Configurations:**

   - Change the variables in [variables.json](./variables.json) to match your desired configuration
     - Note: If `USE_FABRIC` is true, it will install the Fabric launcher along with basic performance mods
   - Set the `pack_id` and your `api_key` in [curseforge_variables.json](./setup/download/json/curseforge_variables.json)

## Usage

Once the above steps are completed, you can run the main setup script:

**Modpack server:**
```bash
sudo -u <username> bash main.sh
```

**Vanilla server:**
```bash
sudo -u <username> bash main-vanilla.sh
```

**Skip auto-start:**
```bash
sudo -u <username> bash main.sh --no-start
```

**Accept all defaults:**
```bash
sudo -u <username> bash main.sh --y
```

**See all options:**
```bash
bash main.sh --help
```

### Runtime Scripts

After setup, management scripts are copied to your server's `scripts/` directory:

- `start.sh` — Start the server via systemd
- `shutdown.sh` — Graceful shutdown with player notification and countdown
- `restart.sh` — Graceful restart with player notification
- `maintenance.sh` — Enter maintenance mode (kicks non-admins, swaps MOTD)
- `backup/backup.sh` — Manual backup with archive mode support
- `backup/restore.sh` — Restore from backup with `--ago`, `--file`, and `--archive` options
- `update/update-server.js` — Update the server version and mods
- `update/check-updates.js` — Check for available mod updates
- `misc/status.sh` — Show server status and online players

## Version Compatibility

This project supports both Minecraft version formats:

| Format | Example | Java Detection |
|--------|---------|----------------|
| Legacy `1.x.y` | `1.21.4` | Dynamic (Mojang API) |
| New `YY.D.H` | `26.1`, `26.1.1` | Dynamic (Mojang API) |

Java version requirements are resolved dynamically by querying Mojang's version manifest API, so no manual updates are needed when new Minecraft versions are released.

Set your desired version in `variables.json`:
```json
{
  "JAVA": {
    "SERVER": {
      "VANILLA": {
        "VERSION": "latest"
      }
    }
  }
}
```

Use `"latest"` for the newest release, or specify an exact version like `"26.1"` or `"1.21.4"`.

## Folder Structure

- **main.sh / main-vanilla.sh:** Entry points for modpack and vanilla server setup.
- **common/:** Shared shell modules (argument parsing, logging, environment, prompts).
- **setup/:** Setup-phase scripts for downloading, configuring, and structuring the server.
- **scripts/:** Runtime scripts copied to the server for day-to-day management.
- **vanilla/:** Vanilla/Fabric-specific setup scripts and mod lists.
- **variables.json:** Main configuration file.
- **package.json:** Node.js dependency management.

## Contributing

Contributions are welcome! If you have suggestions, bug fixes, or enhancements, please follow these steps:

1. Fork the repository.
2. Create a feature or bugfix branch.
3. Make your changes and commit them with clear descriptions.
4. Open a pull request detailing your changes.

For major changes, please open an issue first to discuss what you would like to change.
