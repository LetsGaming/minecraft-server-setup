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
- **Multi-Instance CLI (`manage.sh`):** Status overview, start/stop/restart/backup across multiple server instances from the shell.
- **Remote control via the API wrapper:** Optional HTTP service (`API_SERVER`) that exposes these scripts to the [minecraft-bot](https://github.com/LetsGaming/minecraft-bot) Discord bot and its web dashboard — console, backups, rollback, and live logs, without a second panel on this host.
- **Maintenance Mode:** MOTD swap, non-admin kick monitoring, automatic cleanup on exit.

## Prerequisites

- **OS:** Linux with systemd and cron (Ubuntu/Debian recommended)
- **Bash:** 4.3+
- **Node.js:** 18+
- **Tools:** `curl`, `screen`, `unzip`, `node`, `npm`, `cron`, `rsync`, `zstd`, `jq` and `acl` (`setfacl`) are installed automatically via `download_packages.sh`, which uses `apt`
- **Preflight:** `main.sh --check` verifies `screen`, `rsync`, `zstd`, `tar`, `curl`, `jq`, `unzip`, `cron` and `setfacl` are on the PATH, plus `variables.json`, Node.js, `node_modules`, disk space and the optional CurseForge, RCON, webhook and API settings. `jq` builds the webhook payloads; without it notifications are skipped with a message
- **Install location:** setup writes to `$HOME/<TARGET_DIR_NAME>/`: `instances/<instance>/` (the server), `scripts/<instance>/` (the runtime scripts), `services/api-server/` (the optional wrapper) and, unless `BACKUPS.BACKUPS_PATH` is set, `backups/<instance>/`

## Installation

```bash
git clone https://github.com/LetsGaming/minecraft-server-setup.git
cd minecraft-server-setup
npm install
```

The API wrapper is not in this repository: setup downloads it only when you enable it (see [minecraft-bot API Wrapper](#minecraft-bot-api-wrapper)).

## Configuration

Copy [`variables.example.json`](./variables.example.json) to `variables.json` and edit it. All settings are in one file (if it is missing, the first setup or `--check` run creates the copy and stops so you can edit it). `variables.json` is git-ignored because it holds your RCON password, API key and webhook URL; edit only your copy:

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
    "WARN_SECONDS": 30                // At least 5. INTERVAL_HOURS must divide 24 (1, 2, 3, 4, 6, 8, 12, 24) or be a multiple of 24
  },

  "API_SERVER": {
    "ENABLED": false,                 // true = set up the minecraft-bot API wrapper
    "PORT": 3000,                     // Port the wrapper listens on
    "API_KEY": ""                     // Shared secret, at least 32 characters (openssl rand -hex 32). Must match apiKey in the bot's config.json
    "SERVICE_USER": ""                // Optional: run the wrapper as its own unprivileged user (docs/service-user.md)
  },

  "BACKUPS": { ... },
  "JAVA": { ... }
}
```

For modpack setup, also configure:
- [`curseforge_variables.json`](./src/setup/download/json/curseforge_variables.example.json) — API key and pack ID. This file is git-ignored (it holds your API key). Copy the template first:
  ```bash
  cp src/setup/download/json/curseforge_variables.example.json \
     src/setup/download/json/curseforge_variables.json
  ```
  Setup also falls back to the `.example.json` automatically if the live file is missing, so it will run and tell you to set your key rather than crashing.
- [`modrinth_variables.json`](./src/setup/download/json/modrinth_variables.json) — mod slugs (no API key, kept in version control)

## Usage

### Setup

```bash
# Validate everything first (recommended)
sudo -u <user> bash main.sh --check

# Modpack server
sudo -u <user> bash main.sh

# Vanilla/Fabric server
sudo -u <user> bash main.sh --vanilla

# With minecraft-bot API wrapper (for remote bot deployments)
sudo -u <user> bash main.sh --api-server

# Or via npm
npm run check
npm run setup
```

Options (`--help` lists them):

| Option | Effect |
|---|---|
| `--check` | Validate config, tools and disk space, then exit |
| `--dry-run` | Only print what would be done |
| `--verbose` | Print additional logging info |
| `--no-start` | Do not start the server |
| `--agree-eula` | Accept the EULA |
| `--no-service` | Skip creating the systemd service |
| `--no-backup` | Skip creating the backup job |
| `--api-server` | Set up the minecraft-bot API wrapper service |
| `--vanilla` | Set up a vanilla/Fabric server instead of a modpack |
| `--y` | Skip the prompts and take the defaults. This **accepts the EULA** |

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
| `backup/restore.sh` | Restore from backup (refuses while the server is running; see [docs/backup-restore.md](docs/backup-restore.md)) |
| `update/update-server.js` | Update server version (auto Java install) |
| `update/check-updates.js` | Check for mod updates |
| `misc/status.sh` | Show server status and players |
| `misc/doctor.sh` | Read-only health check of an installed instance (see [Health check](#health-check)) |
| `update/upgrade.sh` | Move to a new Minecraft version as one supervised job (see [docs/upgrade.md](docs/upgrade.md)) |
| `world/prune-chunks.js` | Optional deletion of unused chunks (see [docs/chunk-pruning.md](docs/chunk-pruning.md)) |

The API wrapper is not among these scripts: it runs from `<target>/services/api-server/` (see [minecraft-bot API Wrapper](#minecraft-bot-api-wrapper)).

### Multi-Instance Management

```bash
bash manage.sh list                 # List all instances
bash manage.sh status               # Status of all instances
bash manage.sh restart survival     # Smart-restart a specific instance
bash manage.sh backup creative      # Backup a specific instance
bash manage.sh update survival      # Check mods of a specific instance for updates
```

`manage.sh` also has `start <instance>` and `stop <instance>` (a graceful shutdown); `manage.sh help` lists everything.

### Health check

```bash
sudo bash manage.sh doctor              # every instance
sudo bash manage.sh doctor survival --test-webhook
```

Run it as an admin with sudo. It prints one `OK`, `WARN`, `FAIL` or `SKIP` line per check and exits 1 when any check fails:

- the systemd unit is enabled and running, and has crash-loop limits in `[Unit]` (`migrate.sh` adds them to older units)
- the hourly backup cron job (and the restart job when `RESTART_SCHEDULE.ENABLED`) is in the server user's crontab
- backup usage against `MAX_STORAGE_GB` (warns from 90%, fails above 100%) and free disk space where the backups live (warns under 5 GB)
- the wrapper's sudoers file passes `visudo -c` (skipped without an `API_SERVER.SERVICE_USER`)
- the wrapper answers on its port and accepts the configured API key (skipped unless `API_SERVER.ENABLED`)

`--test-webhook` also sends one `webhook_test` notification regardless of `WEBHOOK_EVENTS` and reports whether the endpoint accepted it. Without the flag nothing is sent.

### RCON vs Screen

Set `SERVER_CONTROL.USE_RCON` in `variables.json`:

- **`false` (default):** Commands sent via `screen -X stuff`. Simple, no extra config. Requires screen session.
- **`true`:** Commands sent via Minecraft's RCON protocol. Reliable, supports response parsing, no screen dependency. Requires `RCON_PASSWORD`. Automatically falls back to screen if RCON connection fails.

### Webhooks

Supports Discord webhooks (auto-detected, sends embeds) and generic JSON webhooks. Events:

| Event | Sent when |
|---|---|
| `backup_complete` | A backup finished and passed validation |
| `backup_failed` | A backup failed |
| `storage_warning` | Backups are still over `MAX_STORAGE_GB` after cleanup evicted every archive it may evict (sent on each hourly cleanup while that stays true) |
| `server_start` | The server came up |
| `server_start_failed` | The server did not come up |
| `server_stop` | `shutdown.sh` stopped the server (`manage.sh stop`, the wrapper's `stop` action). Not sent for a direct `systemctl stop` or a crash |
| `server_restart` | `smart_restart.sh` restarted the server |
| `server_crash_loop` | The server crashed repeatedly and `start.sh` gave up |
| `rollback_start`, `rollback_complete` | A rollback began and finished |
| `update_start` | A version upgrade began |
| `update_complete`, `update_failed` | A version upgrade or update finished or failed |

If `NOTIFICATIONS.WEBHOOK_EVENTS` is empty, every event is sent. A name in the list that no script sends is accepted, but setup warns about it.

## Documentation

| Topic | Doc |
|---|---|
| HTTPS in front of the API wrapper | [docs/reverse-proxy.md](docs/reverse-proxy.md) |
| What backup, restore and rollback do and refuse to do | [docs/backup-restore.md](docs/backup-restore.md) |
| API keys, RCON passwords, `.env` | [docs/secrets-management.md](docs/secrets-management.md) |
| sudo rules the scripts need | [docs/sudoers-setup.md](docs/sudoers-setup.md) |
| Running the wrapper as its own unprivileged user | [docs/service-user.md](docs/service-user.md) |
| Bringing an installed server up to the current suite (`migrate.sh`) | [docs/migrations.md](docs/migrations.md) |
| Moving to a new Minecraft version | [docs/upgrade.md](docs/upgrade.md) |
| Deleting unused chunks before an upgrade | [docs/chunk-pruning.md](docs/chunk-pruning.md), [benchmarks](docs/prune-benchmarks.md) |
| Terms used across the docs | [docs/GLOSSARY.md](docs/GLOSSARY.md) |
| Retiring the bundled web interface | [docs/retiring-web-interface.md](docs/retiring-web-interface.md) |
| Which API wrapper release is installed, and bumping it | [docs/wrapper-release.md](docs/wrapper-release.md) |

## Upgrading to 4.0

**The bundled web interface is gone.** `minecraft-server-manager` was a second
privileged service on this host that duplicated the API wrapper: its own RCON
client, its own `variables.txt` parser, its own instance registry. Everything it
did now lives in the [minecraft-bot](https://github.com/LetsGaming/minecraft-bot)
dashboard, which reaches this host through the wrapper instead of running on it.

`migrate.sh` handles the service side where it finds one — it stops, disables
and removes the unit, then renames the deployment to `services/manager.retired/`
rather than deleting it, because that directory holds the only copy of its
credentials. The rest is a short manual checklist:
[docs/retiring-web-interface.md](docs/retiring-web-interface.md).

The `WEB_INTERFACE` block in `variables.json` is ignored, so an upgrade does not
fail over a leftover key; delete the block when convenient. If it had a
non-empty `BLOCKED_COMMANDS`, those entries move to the bot's `config.json`
under `webui.console.blockedCommands`. The `--interface` flag was removed.

The dashboard's backup panel needs the wrapper's `backup-files` and
`backup-restore` features, and its rollback button needs the `rollback` script
capability. A wrapper without them keeps working; the dashboard hides what it
cannot serve rather than showing controls that fail. The bot reads
`GET /manifest` to find out which features the installed wrapper has.

## Version Compatibility

| Format | Example | Java Detection |
|--------|---------|----------------|
| Legacy `1.x.y` | `1.21.4` | Dynamic (Mojang API) |
| New `YY.D.H` | `26.1`, `26.1.1` | Dynamic (Mojang API) |

Set `"VERSION": "latest"` for newest release, or any specific version string.

## minecraft-bot API Wrapper

The API wrapper is a standalone [mc-api-server](https://github.com/LetsGaming/minecraft-server-api) project. Setup installs the release pinned in [`api-server-release.json`](./api-server-release.json) from GitHub, checked against its sha256, and `migrate.sh` upgrades it when the pin moves ([docs/wrapper-release.md](docs/wrapper-release.md)); a host that does not enable it downloads nothing. It lets the [minecraft-bot](https://github.com/LetsGaming/minecraft-bot) Discord bot manage and monitor this MC instance over HTTP from a different machine.

### When to use it

**Always, if you use minecraft-bot at all.** This used to say the wrapper was
only needed when the bot ran on a different machine — that stopped being true in
bot 5.0.0, which removed every local path (direct RCON, `screen`, `sudo`, local
file reads). The wrapper is now the only way in, same-host or not.

The reason it went that way: every feature written twice, once local and once
remote, drifted, and the drift shipped as bugs. One path means one place for a
bug.

### Setup

Enable it in `variables.json` before running setup:

```json
"API_SERVER": {
  "ENABLED": true,
  "PORT": 3000,
  "API_KEY": "replace-with-a-long-random-secret"
}
```

Then run setup normally: with `API_SERVER.ENABLED` true the wrapper is set up and setup does not ask. With `ENABLED` false, setup asks whether to set it up, or you can pass the flag to skip the question:

```bash
sudo -u <user> bash main.sh --api-server
```

This downloads the pinned wrapper release to `<target>/services/api-server/`, installs its production dependencies and creates and starts a systemd service named `<TARGET_DIR_NAME>-api-server.service`. One wrapper process serves every instance on the machine.

The API key must be at least 32 characters (`openssl rand -hex 32`). `variables.json` validation and `--check` reject a shorter one, and the wrapper refuses to start with it. Pick the same key for `apiKey` in the bot's `config.json`.

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

The port defaults to 3000 (`variables.example.json` sets 3030). Allow inbound TCP on the configured port from the bot VM's IP only:

```bash
ufw allow from <BOT_IP> to any port 3000 proto tcp
```

### Managing the service

```bash
systemctl status <TARGET_DIR_NAME>-api-server
journalctl -u <TARGET_DIR_NAME>-api-server -f
systemctl restart <TARGET_DIR_NAME>-api-server
```

### Standalone deployment

The API server can also be deployed independently without this setup project. See the [mc-api-server README](https://github.com/LetsGaming/minecraft-server-api#readme) for standalone install and configuration instructions.

## Tests

```bash
bash tests/shell/run.sh
```

Runs the shell tests for the backup, restore, rollback, cleanup, webhook and server-control scripts and the Node tests for the update scripts against a scratch instance with fake binaries on `PATH`. See [docs/backup-restore.md](docs/backup-restore.md#tests).

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and commit with clear descriptions
4. Open a pull request

For major changes, open an issue first.
