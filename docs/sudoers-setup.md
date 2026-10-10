# Sudoers Configuration

The setup and management scripts run as a non-root application user (e.g. `mcbot`) but need to execute commands as the Minecraft server user (e.g. `minecraft`) and manage the systemd service.

## Required sudoers entries

Create `/etc/sudoers.d/minecraft-management` with the following content.  
**Always edit sudoers with `sudo /usr/sbin/visudo -f /etc/sudoers.d/minecraft-management`.**

```
# ── Command aliases ────────────────────────────────────────────────────────────

# The RUNTIME actions the app actually issues: start / stop / restart / status.
# enable/disable/daemon-reload and service *creation* are one-time setup steps
# (run by an admin with their own sudo) — the network-facing app user does not
# need them at runtime, so they are deliberately NOT granted here. (SEC-03)

# Game server instance(s) — add a line per instance if you have more than one
# reset-failed: clears a unit's crash-loop-tripped `failed` state (see
# StartLimitBurst in create_service.sh) so start/restart can recover from a
# fixed problem without SSH. show: read-only, lets the health probe report
# NRestarts/ActiveState so the bot can tell a crash loop from a clean outage.
# Both are runtime actions, not setup ones — kept here per the note above.
Cmnd_Alias MC_GAME_SERVER = \
    /usr/bin/systemctl start server.service, \
    /usr/bin/systemctl stop server.service, \
    /usr/bin/systemctl restart server.service, \
    /usr/bin/systemctl status server.service, \
    /usr/bin/systemctl reset-failed server.service, \
    /usr/bin/systemctl show server.service *

# Support services (api-server) — matched by prefix wildcard
Cmnd_Alias MC_SUPPORT_SERVICES = \
    /usr/bin/systemctl start minecraft-server-*.service, \
    /usr/bin/systemctl stop minecraft-server-*.service, \
    /usr/bin/systemctl restart minecraft-server-*.service, \
    /usr/bin/systemctl status minecraft-server-*.service, \
    /usr/bin/systemctl reset-failed minecraft-server-*.service

# ── User grants ────────────────────────────────────────────────────────────────

# Allow the minecraft user to manage its own services
minecraft ALL=(root) NOPASSWD: MC_GAME_SERVER, MC_SUPPORT_SERVICES

# Allow the application user to run management scripts as the minecraft user.
# IMPORTANT (SEC-03): the directories this glob matches MUST be owned by
# `minecraft` and MUST NOT be writable by `mcbot`. If mcbot can write into a
# matched scripts/ directory it can run arbitrary code as minecraft. Prefer
# pinning this to the exact deployed instance directory rather than a wildcard,
# e.g.:
#   mcbot ALL=(minecraft) NOPASSWD: /usr/bin/bash /home/minecraft/mc/instances/survival/scripts/
# NOTE the two patterns: management scripts live at BOTH depths.
#   scripts/start.sh, shutdown.sh, smart_restart.sh, restart.sh, rollback.sh
#   scripts/backup/backup.sh, scripts/backup/restore.sh, scripts/misc/status.sh
# sudo wildcards do not match "/", so a single */* glob silently misses every
# top-level script — including rollback.sh, which the dashboard's Rollback
# button needs. Grant both, and adjust the depth to your actual install path.
mcbot ALL=(minecraft) NOPASSWD: /usr/bin/bash /home/minecraft/*/scripts/*, \
                                /usr/bin/bash /home/minecraft/*/scripts/*/*

# The API wrapper's mod operations (install, remove, update, enable, disable)
# run the update scripts with node, as the minecraft user:
#   sudo -n -u minecraft /usr/bin/node <scripts>/update/<name>.js [flags] --json -- [slug]
# That needs its own grant, separate from the bash scripts above. Without it
# every mod operation fails with a generic sudo error. Name each script and
# the absolute node binary; the trailing * covers the flags. The same
# directory-ownership warning as above applies.
Cmnd_Alias MC_MOD_SCRIPTS = \
    /usr/bin/node /home/minecraft/*/scripts/update/add-mod.js *, \
    /usr/bin/node /home/minecraft/*/scripts/update/remove-mod.js *, \
    /usr/bin/node /home/minecraft/*/scripts/update/update-mod.js *, \
    /usr/bin/node /home/minecraft/*/scripts/update/update-mods.js *, \
    /usr/bin/node /home/minecraft/*/scripts/update/check-updates.js *, \
    /usr/bin/node /home/minecraft/*/scripts/update/toggle-mod.js *
mcbot ALL=(minecraft) NOPASSWD: MC_MOD_SCRIPTS

# Allow the application user to manage all Minecraft services
mcbot ALL=(root) NOPASSWD: MC_GAME_SERVER, MC_SUPPORT_SERVICES
```

Replace `mcbot` and `minecraft` with your actual application and server users, and adjust service names if your instance is named differently.

> **Removed in v3.x (SEC-03):** the old `MC_DEPLOY` alias granted
> `mv /tmp/minecraft-*.service /etc/systemd/system/` to the app user. Because
> `/tmp` is world-writable and that filename was attacker-choosable, it allowed
> the app user to install an arbitrary root systemd unit. Service files are now
> written directly to their final path with `sudo tee` during setup (see
> `src/setup/common/writeRootFile.js`), so this grant is no longer needed or
> recommended. If you previously added it, delete it.

## Absolute paths for bash and node

By default the wrapper starts `bash` and `node` by name and `sudo` resolves them through its `secure_path`. That breaks when node comes from nvm or another per-user install, and it makes the sudoers rule depend on whatever the name resolves to. Pin both:

```bash
command -v bash node          # for example /usr/bin/bash and /usr/bin/node
```

Set `MC_BASH_PATH` and `MC_NODE_PATH` in the wrapper's environment (the systemd unit or `.env`) to those absolute paths, and use exactly the same paths in the sudoers rules above. The wrapper refuses to start if either variable is set to a relative path.

## Default service names

The entries above use the default service names created by the setup script:

| Service | Description |
|---|---|
| `server.service` | The Minecraft game server |
| `minecraft-server-api-server.service` | The API server (mc-api-server) |

If you have multiple game server instances, add a matching set of `server.service` entries for each (e.g. `creative.service`, `survival.service`).

## Verifying the configuration

After saving, verify each user can run their commands without a password:

```bash
# As minecraft user
sudo -n systemctl status server.service

# As mcbot user
sudo -n systemctl status server.service
sudo -n -u minecraft echo "ok"

# The mod scripts (needs a real instance path)
sudo -n -u minecraft /usr/bin/node /home/minecraft/mc/instances/survival/scripts/update/check-updates.js --json
```

If either command asks for a password, the sudoers entry is not applied correctly.

## Principle of least privilege

- Only the four runtime actions (`start`/`stop`/`restart`/`status`) are granted. `enable`, `disable`, `daemon-reload`, and unit-file creation are **setup-time** operations performed by an admin's own sudo — they are intentionally not granted to the app user (SEC-03).
- The `*/scripts/*/*` pattern restricts script execution to files inside an instance's `scripts/` directory. **Those directories must be owned by `minecraft` and not writable by `mcbot`** — otherwise the app user could drop a script there and run it as `minecraft`. Pin the path to the exact instance directory where you can.
- Never grant `ALL=(minecraft) NOPASSWD: ALL` — that gives unlimited shell access as the MC user.
- Never grant a `mv`/`cp`/`tee` from a world-writable location (e.g. `/tmp`) into `/etc/systemd/system/` — that is an arbitrary-root-unit install. Write unit files straight to their final path (the setup scripts now do this).
- `visudo` validates syntax before writing; a malformed sudoers file can lock you out of `sudo` entirely, so always use it instead of editing the file directly.