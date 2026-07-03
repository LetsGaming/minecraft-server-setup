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
Cmnd_Alias MC_GAME_SERVER = \
    /usr/bin/systemctl start server.service, \
    /usr/bin/systemctl stop server.service, \
    /usr/bin/systemctl restart server.service, \
    /usr/bin/systemctl status server.service

# Support services (api-server, manager) — matched by prefix wildcard
Cmnd_Alias MC_SUPPORT_SERVICES = \
    /usr/bin/systemctl start minecraft-server-*.service, \
    /usr/bin/systemctl stop minecraft-server-*.service, \
    /usr/bin/systemctl restart minecraft-server-*.service, \
    /usr/bin/systemctl status minecraft-server-*.service

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
mcbot ALL=(minecraft) NOPASSWD: /usr/bin/bash /home/minecraft/*/scripts/*/*

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

## Default service names

The entries above use the default service names created by the setup script:

| Service | Description |
|---|---|
| `server.service` | The Minecraft game server |
| `minecraft-server-api-server.service` | The API server (mc-api-server) |
| `minecraft-server-manager.service` | The web-based server manager |

If you have multiple game server instances, add a matching set of `server.service` entries for each (e.g. `creative.service`, `survival.service`).

## Verifying the configuration

After saving, verify each user can run their commands without a password:

```bash
# As minecraft user
sudo -n systemctl status server.service

# As mcbot user
sudo -n systemctl status server.service
sudo -n -u minecraft echo "ok"
```

If either command asks for a password, the sudoers entry is not applied correctly.

## Principle of least privilege

- Only the four runtime actions (`start`/`stop`/`restart`/`status`) are granted. `enable`, `disable`, `daemon-reload`, and unit-file creation are **setup-time** operations performed by an admin's own sudo — they are intentionally not granted to the app user (SEC-03).
- The `*/scripts/*/*` pattern restricts script execution to files inside an instance's `scripts/` directory. **Those directories must be owned by `minecraft` and not writable by `mcbot`** — otherwise the app user could drop a script there and run it as `minecraft`. Pin the path to the exact instance directory where you can.
- Never grant `ALL=(minecraft) NOPASSWD: ALL` — that gives unlimited shell access as the MC user.
- Never grant a `mv`/`cp`/`tee` from a world-writable location (e.g. `/tmp`) into `/etc/systemd/system/` — that is an arbitrary-root-unit install. Write unit files straight to their final path (the setup scripts now do this).
- `visudo` validates syntax before writing; a malformed sudoers file can lock you out of `sudo` entirely, so always use it instead of editing the file directly.