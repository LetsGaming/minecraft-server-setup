# Secrets Management

Credentials (RCON password, API key, webhook URL) are read from `variables.json` and written by setup into the instance's `common/variables.txt` (mode 0600) and the wrapper's `api-server-config.json` (mode 0600, readable by the wrapper's own user). `variables.json` is git-ignored and not tracked; it starts as a copy of `variables.example.json`. Both live on disk in plain text, so keep the install directory private and the files' modes as setup leaves them.

## Environment variables

### mc-api-server

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

> The retired web interface used `JWT_SECRET` and `PORT`. If those are still in
> your environment or `.env`, remove them — see
> [retiring-web-interface.md](retiring-web-interface.md). A live `JWT_SECRET`
> for a service that no longer runs is a credential nobody is watching.

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
