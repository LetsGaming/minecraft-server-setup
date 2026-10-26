# Minecraft Server Setup

[![Release](https://img.shields.io/github/v/release/LetsGaming/minecraft-server-setup)](https://github.com/LetsGaming/minecraft-server-setup/releases) ![License: MIT](https://img.shields.io/badge/license-MIT-green) ![Platform: Ubuntu / Debian](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-orange) ![Shell: Bash 4.3+](https://img.shields.io/badge/bash-4.3%2B-blue)

## What is this

This tool turns a fresh Ubuntu or Debian computer into a Minecraft server that your friends can join. It installs what the server needs, sets the server up, starts it automatically when the machine boots and makes regular backups. You do not need to know how to edit configuration files or how much memory to give the server: the tool looks at your machine and picks safe values.

Beyond setup it manages the server afterwards: backup rotation, mod updates, RCON support, webhook notifications and multi-instance management.

## Quick start

```bash
git clone https://github.com/LetsGaming/minecraft-server-setup.git
cd minecraft-server-setup
bash main.sh
```

Something not working? See [docs/troubleshooting.md](docs/troubleshooting.md).

Run it as a normal user with `sudo` rights, not as root. Setup installs whatever is missing, asks a few questions (or uses safe defaults), and then sets up the server, the systemd service and the backups. Anything it changes for safety (for example a smaller memory size or a different port) is shown in a clearly marked block and repeated before you confirm.

## How setup works: three routes

| Route | For | What happens |
|---|---|---|
| **Default** | Anyone who just wants a server | Almost no questions. Setup checks your machine, picks safe values, shows a summary of everything it will do and everything it changed, asks you to confirm and to accept the Minecraft EULA, then installs. The result is a Fabric server on a Minecraft version that works with the default mods, with backups on. |
| **Guided** | Someone who wants to choose | A step-by-step menu (whiptail, with Back and Cancel) that explains each choice: server type, version, name, memory, backups, restart schedule, webhook and API wrapper. Safe values are prefilled and the same corrections apply. |
| **Power-user** | Admins and automation | No wizard. Setup reads your own `variables.json` and the command-line flags below. |

Which route runs:

- If `variables.json` already exists, or there is no terminal (for example a script or a pipe), the **Power-user** route runs. With no `variables.json` and no terminal, setup creates the file from the example and stops with instructions, as before.
- Otherwise you choose between Default and Guided on the first screen (a plain-text prompt where "Quick setup (recommended)" is the Default route and "Guided setup" is the Guided route), with Default preselected.
- `--default` and `--guided` pick a route directly. `--default` without a terminal also needs `--agree-eula`, because the EULA is never accepted silently. `--guided` needs a terminal. Both flags need that there is no `variables.json` yet and stop with a message if one exists. A plain `bash main.sh` reuses an existing `variables.json` (the Power-user route), which is also how a failed install is retried.
- Default and Guided both finish by writing a `variables.json`, so the next run uses the Power-user route with the same choices. If an install fails, that file stays: run again to retry, or delete it to start over.
- Setup never overwrites an existing instance. If the name `server` is taken, the Default route uses the next free name (`server-2`, `server-3`, ...) and tells you.

## Reaching your server from outside your network

Setup does not configure your router and cannot tell whether it is configured. At the end of the Default and Guided routes it prints this notice with the actual port and the machine's local address. The Power-user route does not print it: there the port is `JAVA.SERVER.PORT` (25565 by default).

- **Friends on the same network** join with the machine's local address and the server port.
- **Friends elsewhere** need two things: your router must forward the server's TCP port to this machine, and they need your public address or a dynamic-DNS name. The port is 25565 unless that port was already in use, in which case setup picks the next free one and prints it. Look for "port forwarding" in your router's settings, then test the public address from outside your home network.

## Features

- **Version-Agnostic:** Supports both legacy `1.x.y` and the new `YY.D.H` format (e.g. `26.1`).
- **Dynamic Java Detection:** Resolves required Java version from Mojang's API — zero maintenance.
- **Auto Java Install:** Updates automatically install the correct Java version via Jabba if missing.
- **RCON + Screen Dual Mode:** Use RCON for reliable command dispatch, or screen for simplicity. Automatic fallback if RCON fails.
- **Webhook Notifications:** Discord or generic webhook alerts for backups, updates, restarts, and failures.
- **Backup System:** Grandfather-father-son rotation with zstd compression, archive validation, configurable retention, and crash-safe auto-save handling.
- **Server Rollback:** One-command rollback to the most recent pre-update backup.
- **Smart Restart:** Player-aware restarts that skip warnings when nobody is online.
- **Scheduled Restarts:** Configurable automatic restart on a systemd timer with player-count awareness.
- **Mod Conflict Detection:** Update checker warns about incompatible mods before applying changes.
- **Preflight Check:** `--check` flag validates config, tools, disk space, and API keys without running setup.
- **Multi-Instance CLI (`manage.sh`):** Status overview, start/stop/restart/backup across multiple server instances from the shell.
- **Remote control via the API wrapper:** Optional HTTP service (`API_SERVER`) that exposes these scripts to the [minecraft-bot](https://github.com/LetsGaming/minecraft-bot) Discord bot and its web dashboard — console, backups, rollback, and live logs, without a second panel on this host.
- **Maintenance Mode:** MOTD swap, non-admin kick monitoring, automatic cleanup on exit.
- **Creative mirror (optional):** a second server where players build in creative mode on a nightly copy of your survival world, with flat build plots next to it. Set up on existing servers or together with a new one; nothing else in the suite depends on it. See [docs/mirror.md](docs/mirror.md).

## Prerequisites

- **OS:** Linux with systemd (Ubuntu/Debian recommended). The backup and restart jobs run as systemd timers; on a host without a running systemd (a container, WSL) setup falls back to cron lines, which is why `cron` is still installed
- **Bash:** 4.3+
- **Tools:** setup installs only what is missing, with `apt`, before it asks anything: `curl`, `screen`, `unzip`, `cron`, `rsync`, `zstd`, `jq`, `acl` (`setfacl`), Node.js with `npm`, and `whiptail` on the Guided route only. It runs `npm ci --omit=dev` for you, so there is no `npm install` step. It does not upgrade the system unless you set `MC_SETUP_UPGRADE_SYSTEM=true`.
- **Node.js 18+:** setup applies this policy. An installed Node 18 or newer is used as is. Otherwise, if the distribution's own `nodejs` package is 18 or newer, that package is installed. Otherwise (for example Ubuntu 22.04 or Debian 11) Node 22 would come from the NodeSource apt repository, which is a third-party repository, so setup only does that when you pass `--allow-nodesource`. Without the flag it stops and prints the manual commands.
- **Preflight:** `main.sh --check` verifies `screen`, `rsync`, `zstd`, `tar`, `curl`, `jq`, `unzip`, `cron` and `setfacl` are on the PATH, plus `variables.json`, Node.js, `node_modules`, disk space and the optional CurseForge, RCON, webhook and API settings. `jq` builds the webhook payloads; without it notifications are skipped with a message
- **Install location:** setup writes to `$HOME/<TARGET_DIR_NAME>/`: `instances/<instance>/` (the server), `scripts/<instance>/` (the runtime scripts), `services/api-server/` (the optional wrapper) and, unless `BACKUPS.BACKUPS_PATH` is set, `backups/<instance>/`

## Installation

Follow the [Quick start](#quick-start). The API wrapper is not in this repository: setup downloads it only when you enable it (see [minecraft-bot API Wrapper](#minecraft-bot-api-wrapper)).

## Configuration

Copy [`variables.example.json`](./variables.example.json) to `variables.json` and edit it. All settings are in one file (if it is missing, the first setup or `--check` run creates the copy and stops so you can edit it). `variables.json` is git-ignored because it holds your RCON password, API key and webhook URL; edit only your copy.

`variables.json` must be strict JSON: no comments and no trailing commas. A single mistake makes setup stop with a parse error. This is an excerpt that shows the main blocks; start from the full example file.

```json
{
  "INSTANCE_NAME": "survival",
  "TARGET_DIR_NAME": "minecraft-server",

  "SERVER_CONTROL": {
    "USE_RCON": false,
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
    "SKIP_IF_EMPTY": true,
    "WARN_SECONDS": 30
  },

  "API_SERVER": {
    "ENABLED": false,
    "PORT": 3000,
    "API_KEY": "",
    "SERVICE_USER": ""
  },

  "JAVA": {
    "SERVER": {
      "PORT": 25565,
      "VANILLA": {
        "MODS": {
          "EXCLUDE": []
        }
      }
    }
  }
}
```

What the keys mean:

| Key | Meaning |
|---|---|
| `INSTANCE_NAME` | Used for the systemd unit, the screen session and the directories |
| `SERVER_CONTROL.USE_RCON` | `true` sends commands over RCON, `false` uses screen |
| `RESTART_SCHEDULE.SKIP_IF_EMPTY` | Skip the warning if no players are online |
| `RESTART_SCHEDULE.WARN_SECONDS` | At least 5. `INTERVAL_HOURS` must divide 24 (1, 2, 3, 4, 6, 8, 12, 24) or be a multiple of 24 |
| `API_SERVER.ENABLED` | `true` sets up the minecraft-bot API wrapper |
| `API_SERVER.PORT` | Port the wrapper listens on. Defaults to 3000 when the key is left out; `variables.example.json` sets 3030 |
| `API_SERVER.API_KEY` | Shared secret, at least 32 characters (`openssl rand -hex 32`). Must match `apiKey` in the bot's `config.json` |
| `API_SERVER.SERVICE_USER` | Optional: run the wrapper as its own unprivileged user ([docs/service-user.md](docs/service-user.md)) |
| `JAVA.SERVER.PORT` | Port the Minecraft server listens on, written to `server-port` in `server.properties`. Optional, default 25565 |
| `JAVA.SERVER.VANILLA.MODS.EXCLUDE` | Optional list of mod slugs left out of the install, for example `["c2me-fabric"]`. Without it, one mod that has no build for your Minecraft version fails the whole install. The Default route fills it in when it has to drop a mod |

`BACKUPS` and the rest of `JAVA` (Java arguments, difficulty, MOTD and so on) are in the example file.

### Xaero's Minimap and World Map

Both mods are optional on the client, and the suite never installs XaeroPlus. When a Xaero mod is in the server's `mods/` folder, setup writes three config lines under `config/xaero/` so players who do not have the mods can still join:

| File | Key | Value |
|---|---|---|
| `lib/common.cfg` | `everyone_tracks_everyone` | `true` |
| `minimap/common.cfg` | `register_minimap_status_effects` | `false` |
| `world-map/common.cfg` | `register_status_effects` | `false` |

Each line is written only when its mod is present: the minimap line when the Minimap jar is in `mods/`, the world-map line when the World Map jar is, and the `lib` line when either is. Only these lines are touched; a missing file is created containing only the key line. Setup creates each file with only its one line and the mods fill in their other defaults on first start; this has not been verified against every Xaero version, and `manage.sh doctor` shows if a line is missing or changed. They are checked again after mod updates, and `manage.sh doctor` reports a missing or changed key. To apply them again by hand:

```bash
bash <target>/scripts/<instance>/misc/xaero_config.sh apply <server_dir>
```

Restart the server afterwards for the change to take effect.

For modpack setup (`--modpack`), also configure:
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
# First time, as the user who will own the server: setup installs what is missing and asks what it needs
bash main.sh

# Read-only check of config, tools and disk space (separate from the three routes)
sudo -u <user> bash main.sh --check

# Power-user route: run setup from your own variables.json (vanilla/Fabric server; use sudo -u <user> to run it as another user)
sudo -u <user> bash main.sh

# CurseForge modpack server instead (needs curseforge_variables.json)
sudo -u <user> bash main.sh --modpack

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
| `--mirror-source` | Also set this server up as the survival side of the optional creative mirror ([docs/mirror.md](docs/mirror.md)) |
| `--mirror-target` | Also prepare this server as the creative side of the mirror. With `--default` or `--guided` add `--mirror-remote` and `--mirror-seed`, or you are asked for them |
| `--mirror-remote=HOST` | The survival server for `--mirror-target`: a host or IP, optionally `mcsync@host` |
| `--mirror-seed=SEED` | The survival world's `level-seed`, for `--mirror-target` |
| `--instance-name=NAME` | Name of the server instance on the Default route (default `server`); the service, the folders and the bot's instance id use it |
| `--modpack` | Set up a CurseForge modpack server instead of the default vanilla/Fabric server |
| `--y` | Skip the prompts and take the defaults. This **accepts the EULA** |
| `--default` | Run the Default route: safe defaults, almost no questions. Without a terminal it needs `--agree-eula` |
| `--guided` | Run the Guided route: the whiptail wizard. Needs a terminal |
| `--allow-nodesource` | Allow adding the third-party NodeSource apt repository to install Node 22 when no Node 18+ is available from the system |

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
- the hourly backup job (and the restart job when `RESTART_SCHEDULE.ENABLED`) is scheduled: a `<instance>-backup.timer` (and `<instance>-restart.timer`) that is enabled and whose last run succeeded, or a crontab line on a host without systemd; it warns when a job has both and would run twice
- backup usage against `MAX_STORAGE_GB` (warns from 90%, fails above 100%) and free disk space where the backups live (warns under 5 GB)
- the last backup run recorded in `.meta/last_backup.json` (fails when it failed, warns when the last success is 3 hours old or more)
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
| `backup_failed` | A backup failed (the message names the stage: preflight, quiesce, stage, compress, verify or publish), timed out, or an archive tier was given up for the day |
| `backup_skipped` | `BACKUP_SKIP_ALERT_AFTER` (default 3) hourly runs in a row were skipped because another backup or operation holds the lock |
| `storage_warning` | Backups are still over `MAX_STORAGE_GB` after cleanup evicted every archive it may evict (sent on each hourly cleanup while that stays true) |
| `server_start` | The server came up |
| `server_start_failed` | The server did not come up |
| `server_stop` | `shutdown.sh` stopped the server (`manage.sh stop`, the wrapper's `stop` action). Not sent for a direct `systemctl stop` or a crash |
| `server_restart` | `smart_restart.sh` restarted the server |
| `server_crash_loop` | The server crashed repeatedly and `start.sh` gave up |
| `rollback_start`, `rollback_complete` | A rollback began and finished |
| `update_start` | A version upgrade began |
| `update_complete`, `update_failed` | A version upgrade or update finished or failed |
| `mirror_export_failed` | Only with the optional creative mirror: the survival server's nightly export failed |
| `mirror_sync_complete`, `mirror_sync_failed` | Only with the optional creative mirror: the creative server's nightly refresh finished or failed (an interrupted swap that was repaired is reported as complete) |

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
| A creative server that mirrors the survival world nightly (optional) | [docs/mirror.md](docs/mirror.md) |
| Deleting unused chunks before an upgrade | [docs/chunk-pruning.md](docs/chunk-pruning.md), [benchmarks](docs/prune-benchmarks.md) |
| Terms used across the docs | [docs/GLOSSARY.md](docs/GLOSSARY.md) |
| Retiring the bundled web interface | [docs/retiring-web-interface.md](docs/retiring-web-interface.md) |
| Which API wrapper release is installed, and bumping it | [docs/wrapper-release.md](docs/wrapper-release.md) |
| Connection, Node.js, backup and service problems | [docs/troubleshooting.md](docs/troubleshooting.md) |

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

The port is `API_SERVER.PORT`, and 3000 when that key is left out (`variables.example.json` sets 3030; the examples here use 3000). Allow inbound TCP on the configured port from the bot VM's IP only:

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
