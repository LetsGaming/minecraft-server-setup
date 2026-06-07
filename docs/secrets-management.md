# Secrets Management

By default, credentials (RCON passwords, API keys, webhook URLs) are stored in `variables.json`. This file is git-ignored but lives on disk in plaintext. For production deployments, use environment variables instead.

## Environment variables

### minecraft-api-server

| Variable | Overrides |
|---|---|
| `MC_API_KEY` | `API_KEY` in `api-server-config.json` |
| `MC_PORT` | HTTP listen port |
| `RCON_PASSWORD_<ID>` | RCON password for instance `<ID>` (e.g. `RCON_PASSWORD_SURVIVAL`) |

### minecraft-bot

| Variable | Overrides |
|---|---|
| `DISCORD_TOKEN` | `token` in `config.json` |
| `DISCORD_CLIENT_ID` | `clientId` in `config.json` |
| `RCON_PASSWORD` | RCON password for all servers |
| `RCON_PASSWORD_<ID>` | RCON password for a specific server |

### minecraft-server-manager

| Variable | Purpose |
|---|---|
| `JWT_SECRET` | Signs session tokens — **required for session persistence across restarts** |
| `PORT` | HTTP listen port |

## Docker Compose example

```yaml
services:
  minecraft-bot:
    image: your-bot-image
    environment:
      DISCORD_TOKEN: ${DISCORD_TOKEN}
      RCON_PASSWORD_SURVIVAL: ${RCON_PASSWORD_SURVIVAL}
    secrets:
      - discord_token

secrets:
  discord_token:
    external: true
```

## Cleaning credentials from git history

If you accidentally committed `variables.json` with live credentials:

```bash
# Install git-filter-repo
pip install git-filter-repo

# Remove the file from all commits
git filter-repo --path variables.json --invert-paths

# Force-push (coordinate with all collaborators first)
git push --force-with-lease origin main
```

After cleaning, rotate all affected credentials immediately.
