# minecraft-bot API Server

A lightweight HTTP wrapper for managing a Minecraft server instance. Exposes server operations (start, stop, restart, backup, stats, RCON commands) over a simple REST API, secured with an API key.

---

## Prerequisites

- **Node.js 18+** — `node --version` should print `v18.x` or higher
- **PM2** — `npm install -g pm2`
- **`sudo` configured** — see [Sudoers Setup](#sudoers-setup) below
- **GNU `screen`** — required for the non-RCON `screen`-based fallback

---

## Installation

```bash
# From the api-server/ directory:
npm install
```

---

## Configuration — `variables.txt`

The server reads all configuration from `../common/variables.txt` (two levels up from `api-server/`). Create or update this file with the following keys:

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `API_SERVER_PORT` | No | `3000` | Port the HTTP server listens on |
| `API_SERVER_KEY` | No | _(none)_ | API key for all authenticated routes. If empty, auth is disabled — **do not leave empty in production** |
| `SERVER_PATH` | **Yes** | — | Absolute path to the Minecraft server directory (contains `server.jar`, `server.properties`, `logs/`) |
| `INSTANCE_NAME` | **Yes** | `server` | Name of the `screen` session and PM2 process (e.g. `survival`) |
| `USER` | No | `minecraft` | Linux user that owns the Minecraft process and screen session |
| `USE_RCON` | No | `false` | Set to `true` to enable RCON for commands and player list queries |
| `RCON_HOST` | No | `localhost` | RCON host |
| `RCON_PORT` | No | `25575` | RCON port |
| `RCON_PASSWORD` | No | _(none)_ | RCON password (must match `server.properties`) |
| `BACKUPS_PATH` | No | _(none)_ | Absolute path to the backups root directory (used by `/backups` endpoint) |

**Example `variables.txt`:**
```
INSTANCE_NAME="survival"
SERVER_PATH="/opt/minecraft/survival"
USER="minecraft"
API_SERVER_PORT="3001"
API_SERVER_KEY="change-me-to-a-random-secret"
USE_RCON="true"
RCON_HOST="localhost"
RCON_PORT="25575"
RCON_PASSWORD="your-rcon-password"
BACKUPS_PATH="/opt/minecraft/backups/survival"
```

---

## Running

### Development
```bash
npm start
```

### Production (PM2)
```bash
# From the api-server/ directory:
pm2 start ecosystem.config.cjs --env production
pm2 save

# To auto-start on boot (run the printed command as root):
pm2 startup
```

Logs are written to `./logs/pm2-out.log` and `./logs/pm2-error.log`.

---

## API Reference

All routes except `/health` require the `x-api-key` header matching `API_SERVER_KEY`.

### Health

#### `GET /health`
Returns `{ "ok": true }`. No authentication required. Safe for uptime monitors.

---

### Instance Routes

All instance routes are prefixed with `/instances/:id`, where `:id` must exactly match `INSTANCE_NAME`.

#### `GET /instances/:id/running`
Returns whether the server process is alive.
```json
{ "running": true }
```

#### `GET /instances/:id/list`
Returns online player count and names.
```json
{ "playerCount": "3", "maxPlayers": "20", "players": ["Alice", "Bob", "Carol"] }
```

#### `GET /instances/:id/tps`
Returns TPS data (requires RCON). Returns `{ "tps": null }` if RCON is disabled or the server is not running.
```json
{ "tps": { "type": "paper", "tps1m": 20.0, "tps5m": 19.8, "tps15m": 19.9, "raw": "..." } }
```

#### `GET /instances/:id/level-name`
Returns the configured world name from `server.properties`.
```json
{ "levelName": "world" }
```

#### `GET /instances/:id/whitelist`
Returns the whitelist from `whitelist.json`.
```json
{ "whitelist": [{ "uuid": "...", "name": "Alice" }] }
```

#### `GET /instances/:id/mods`
Returns the mod slugs from `downloaded_versions.json`. Returns `404` if the file does not exist.
```json
{ "slugs": ["fabric-api", "lithium"], "mtimeMs": 1713456789000 }
```

#### `GET /instances/:id/backups`
Returns metadata about available backups.
```json
{ "dirs": [{ "dir": "hourly", "count": 12, "latestFile": "...", "latestMtimeMs": ..., "latestSizeBytes": ... }], "totalBytes": 2147483648 }
```

---

### Log Routes

#### `GET /instances/:id/logs/tail?lines=N`
Returns the last N lines of `latest.log` (1–500, default 10).
```json
{ "output": "[12:00:00] [Server thread/INFO]: Done (1.234s)!\n..." }
```

#### `GET /instances/:id/logs/stream`
Server-Sent Events stream of new log lines. Each event has the form:
```
data: {"line":"[12:00:01] ...", "serverId":"survival"}
```
Heartbeat comments (`:heartbeat`) are sent every 20 seconds to keep the connection alive.

---

### Stats Routes

#### `GET /instances/:id/stats`
Returns a list of player UUIDs that have stats files.
```json
{ "uuids": ["550e8400-e29b-41d4-a716-446655440000"] }
```

#### `GET /instances/:id/stats/:uuid`
Returns the stats JSON for a specific player UUID. `:uuid` must be a valid lowercase UUID (e.g. `550e8400-e29b-41d4-a716-446655440000`). Returns `404` if no stats file exists for that UUID.
```json
{ "stats": { "minecraft:custom": { ... } } }
```

---

### Command & Script Routes

#### `POST /instances/:id/command`
Send a command to the server via RCON (if enabled) or `screen`.
```json
// Request
{ "command": "/say Hello world" }

// Response
{ "result": "" }
```

#### `POST /instances/:id/scripts/run`
Run a server management script.
```json
// Request
{ "action": "backup", "args": [] }

// Response
{ "output": "Backup complete.", "stderr": "", "exitCode": 0 }
```

Valid `action` values: `start`, `stop`, `restart`, `backup`, `status`.

`args` is optional. If provided, it must be an array of up to 5 strings; each string may only contain alphanumeric characters, `.`, `@`, `/`, or `-` (max 128 chars each).

---

## Sudoers Setup

The API server runs management scripts and `screen` commands as `LINUX_USER` via `sudo -n` (no-password sudo). Without this configuration, script routes will fail with a `[SUDO ERROR]` response.

See `docs/sudoers-setup.md` for the required sudoers configuration.

---

## Running Tests

```bash
npm test
```

Tests use Node's built-in `node:test` runner (Node 18+). No additional dependencies required.

---

## Troubleshooting

**`variables.txt not found`** — ensure the file exists at `../common/variables.txt` relative to `api-server/`, i.e. `scripts/<instance>/common/variables.txt`.

**`RCON auth failed`** — check that `RCON_PASSWORD` in `variables.txt` matches `rcon.password` in `server.properties`, and that `enable-rcon=true` is set in `server.properties`.

**`Script not found`** — the scripts directory is expected at `../` relative to `api-server/`. Ensure `start.sh`, `shutdown.sh`, etc. exist at the expected paths.

**`Sudo not configured`** — follow the sudoers setup guide at `docs/sudoers-setup.md`.

**Log stream disconnects** — heartbeats are sent every 20 seconds. If your proxy has a shorter idle timeout, configure it to pass SSE connections through or increase the timeout.
