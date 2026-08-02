# Retiring the bundled web interface

The suite used to ship a web panel (`minecraft-server-manager`) as a git
submodule, deployed to `<install-root>/services/manager/` and run as
`<target>-manager.service`. It is gone.

Everything it did now lives in the **minecraft-bot dashboard**, which reaches
this host through the API wrapper (`API_SERVER` in `variables.json`) rather than
running on it.

## Why it was removed

The panel was not really a second dashboard, it was a second *wrapper*. It ran
on the Minecraft host, shelled out to these same scripts, and carried its own
RCON client, its own `variables.txt` parser and its own instance registry. Two
privileged local services on one machine, for one capability, each with its own
copy of the same logic to drift apart.

## What replaces what

| Web interface | Now |
|---|---|
| Login (local username/password) | Discord OAuth2 in the dashboard, with per-capability grants |
| Instance list, status | Dashboard → Servers |
| Start, shutdown, restart | Dashboard → Servers |
| Rollback | Dashboard → Servers (needs `rollback.sh`, which this suite installs) |
| Console command, live terminal | Dashboard → Console |
| Log tail | Dashboard → Console |
| Backup list, download, restore | Dashboard → Backups (needs `backup/restore.sh`, installed here) |
| `BLOCKED_COMMANDS` | The bot's `config.json`, under `webui.console.blockedCommands` |
| Public status page | Not replaced |

The dashboard needs **API wrapper 3.3.0 or newer** for the backup panel and the
rollback button. Older wrappers still work; the dashboard hides what they cannot
serve rather than showing controls that fail.

## If you are upgrading

`migrate.sh` handles the service half automatically where it finds one:

- stops, disables and removes `<target>-manager.service`, then reloads systemd
- renames `services/manager/` to `services/manager.retired/`

It stops short of deleting anything. The retired directory holds `users.json`,
which is the only copy of those credentials, and a migration script that
silently shreds credentials is one people stop trusting.

Once you are sure you do not need them:

```bash
sudo shred -u <install-root>/services/manager.retired/src/config/users.json
sudo rm -rf <install-root>/services/manager.retired
```

Do that sooner rather than later. A stopped service whose credentials are still
on disk is a login waiting to be switched back on by someone who is not you.

## Cleaning up the rest by hand

**`variables.json`** — the `WEB_INTERFACE` block is ignored now. Setup warns
about it once and carries on; delete the block when convenient. If it had a
non-empty `BLOCKED_COMMANDS`, move those entries to the bot's
`webui.console.blockedCommands`.

**Reverse proxy** — remove the vhost for port 3001. See
[reverse-proxy.md](reverse-proxy.md).

**Environment** — drop `JWT_SECRET` and the panel's `PORT` from `.env` or your
secret store. See [secrets-management.md](secrets-management.md).

**sudoers** — nothing to change. The panel used the same grants the API wrapper
does, and those are still needed. See [sudoers-setup.md](sudoers-setup.md), but
do check the two script-path patterns there: `rollback.sh` sits at the top level
of `scripts/`, and a sudo rule matching only `scripts/*/*` misses it.

**Firewall** — if you opened port 3001, close it.

## Checking a host is clean

```bash
# No unit left behind
systemctl list-unit-files | grep -- '-manager.service' || echo "clean"

# Nothing listening on the old port
ss -tlnp | grep :3001 || echo "clean"

# No credentials left on disk
find <install-root> -name users.json 2>/dev/null || echo "clean"
```

## What the suite still provides

The scripts the dashboard drives are unchanged and stay here: `start.sh`,
`shutdown.sh`, `smart_restart.sh`, `rollback.sh`, `backup/backup.sh`,
`backup/restore.sh`, `misc/status.sh`. The API wrapper discovers which of them
exist and reports that to the bot, which is how the dashboard decides what to
show.
