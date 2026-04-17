# Minecraft Server Setup

Automated Minecraft server setup and management with backup rotation, mod updates, RCON support, webhook notifications, and multi-instance management.

## Features

- **Version-Agnostic:** Supports both legacy `1.x.y` and the new `YY.D.H` format (e.g. `26.1`).
- **Dynamic Java Detection:** Resolves required Java version from Mojang's API — zero maintenance.
- **Auto Java Install:** Updates automatically install the correct Java version via Jabba if missing.
- **RCON + Screen Dual Mode:** Use RCON for reliable command dispatch, or screen for simplicity. Automatic fallback if RCON fails.
- **Webhook Notifications:** Discord or generic webhook alerts for backups, updates, restarts, and failures.
- **Backup System:** Grandfather-father-son rotation with zstd compression, archive validation, configurable retention, and crash-safe auto-save handling.
- **Server Rollback:** One-command rollback to the most recent pre-update backup.
- **Smart Restart:** Player-aware restarts that skip warnings when nobody is online.
- **Scheduled Restarts:** Configurable automatic restart cron with player-count awareness.
- **Mod Conflict Detection:** Update checker warns about incompatible mods before applying changes.
- **Preflight Check:** `--check` flag validates config, tools, disk space, and API keys without running setup.
- **Multi-Instance Manager:** Status overview, start/stop/restart/backup across multiple server instances.
- **Maintenance Mode:** MOTD swap, non-admin kick monitoring, automatic cleanup on exit.

## Prerequisites

- **OS:** Linux (Ubuntu/Debian recommended), macOS, or WSL
- **Bash:** 4.0+
- **Node.js:** 18+
- **Tools:** `screen`, `rsync`, `zstd`, `curl` (installed automatically via `download_packages.sh`)

## Installation

```bash
git clone https://github.com/LetsGaming/minecraft-server-setup.git
cd minecraft-server-setup
npm install
```

## Configuration

Edit [`variables.json`](./variables.json) — all settings are in one file:

```jsonc
{
  "INSTANCE_NAME": "survival",       // Used for systemd, screen, directories
  "TARGET_DIR_NAME": "minecraft-server",

  "SERVER_CONTROL": {
    "USE_RCON": false,                // true = use RCON, false = use screen
    "RCON_PORT": 25575,
    "RCON_PASSWORD": "your-password",
    "RCON_HOST": "localhost"
  },

  "NOTIFICATIONS": {
    "WEBHOOK_URL": "https://discord.com/api/webhooks/...",
    "WEBHOOK_EVENTS": ["backup_complete", "backup_failed", "update_complete", "server_start"]
  },

  "RESTART_SCHEDULE": {
    "ENABLED": false,
    "INTERVAL_HOURS": 12,
    "SKIP_IF_EMPTY": true,            // Skip warning if no players online
    "WARN_SECONDS": 30
  },

  "API_SERVER": {
    "ENABLED": false,                 // true = set up the minecraft-bot API wrapper
    "PORT": 3000,                     // Port the wrapper listens on
    "API_KEY": ""                     // Shared secret — must match apiKey in the bot's config.json
  },

  "BACKUPS": { ... },
  "JAVA": { ... }
}
```

For modpack setup, also configure:
- [`curseforge_variables.json`](./setup/download/json/curseforge_variables.json) — API key and pack ID
- [`modrinth_variables.json`](./setup/download/json/modrinth_variables.json) — mod slugs

## Usage

### Setup

```bash
# Validate everything first (recommended)
sudo -u <user> bash main.sh --check

# Modpack server
sudo -u <user> bash main.sh

# Vanilla/Fabric server
sudo -u <user> bash main-vanilla.sh

# With minecraft-bot API wrapper (for remote bot deployments)
sudo -u <user> bash main.sh --api-server

# Or via npm
npm run check
npm run setup
```

### Runtime Scripts

After setup, management scripts are in `<target>/scripts/<instance>/`:

| Script | Description |
|--------|-------------|
| `start.sh` | Start the server via systemd |
| `shutdown.sh` | Graceful shutdown with player notification |
| `restart.sh` | Graceful restart with countdown |
| `smart_restart.sh` | Player-aware restart (skips warning if empty) |
| `rollback.sh` | Rollback to most recent pre-update backup |
| `maintenance.sh` | Maintenance mode with admin whitelist |
| `manage.sh` | Multi-instance management |
| `backup/backup.sh` | Manual backup with archive mode |
| `backup/restore.sh` | Restore from backup |
| `update/update-server.js` | Update server version (auto Java install) |
| `update/check-updates.js` | Check for mod updates |
| `misc/status.sh` | Show server status and players |
| `api-server/index.js` | minecraft-bot HTTP API wrapper (managed by systemd) |

### Multi-Instance Management

```bash
bash manage.sh list                 # List all instances
bash manage.sh status               # Status of all instances
bash manage.sh restart survival     # Smart-restart a specific instance
bash manage.sh backup creative      # Backup a specific instance
```

### RCON vs Screen

Set `SERVER_CONTROL.USE_RCON` in `variables.json`:

- **`false` (default):** Commands sent via `screen -X stuff`. Simple, no extra config. Requires screen session.
- **`true`:** Commands sent via Minecraft's RCON protocol. Reliable, supports response parsing, no screen dependency. Requires `RCON_PASSWORD`. Automatically falls back to screen if RCON connection fails.

### Webhooks

Supports Discord webhooks (auto-detected, sends embeds) and generic JSON webhooks. Events:

`backup_complete`, `backup_failed`, `update_complete`, `update_failed`, `server_start`, `server_stop`, `server_restart`, `storage_warning`, `rollback_complete`, `rollback_start`

## Version Compatibility

| Format | Example | Java Detection |
|--------|---------|----------------|
| Legacy `1.x.y` | `1.21.4` | Dynamic (Mojang API) |
| New `YY.D.H` | `26.1`, `26.1.1` | Dynamic (Mojang API) |

Set `"VERSION": "latest"` for newest release, or any specific version string.

## minecraft-bot API Wrapper

The setup includes an HTTP API wrapper (`scripts/api-server/index.js`) for the [minecraft-bot](https://github.com/LetsGaming/minecraft-bot) Discord bot. It lets the bot manage and monitor this MC instance from a different machine.

### When to use it

Only needed when the bot runs on a **different VM** from the MC server. If both run on the same machine, the bot accesses files and scripts directly — no wrapper needed.

### Setup

Enable it in `variables.json` before running setup:

```json
"API_SERVER": {
  "ENABLED": true,
  "PORT": 3000,
  "API_KEY": "replace-with-a-long-random-secret"
}
```

Then run setup normally (it will prompt) or pass the flag explicitly:

```bash
sudo -u <user> bash main.sh --api-server
```

This installs `express`, creates, and starts a systemd service named `<INSTANCE_NAME>-api-server.service`.

### Bot configuration

In the bot's `config.json`, add `apiUrl` and `apiKey` to the server entry:

```json
"servers": {
  "survival": {
    "apiUrl": "http://<MC_SERVER_IP>:3000",
    "apiKey": "replace-with-a-long-random-secret"
  }
}
```

### Firewall

Allow inbound TCP on the configured port from the bot VM's IP only:

```bash
ufw allow from <BOT_IP> to any port 3000 proto tcp
```

### Managing the service

```bash
systemctl status survival-api-server
journalctl -u survival-api-server -f
systemctl restart survival-api-server
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and commit with clear descriptions
4. Open a pull request

For major changes, open an issue first.
