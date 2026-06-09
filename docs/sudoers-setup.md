# Sudoers Configuration

The setup and management scripts run as a non-root application user (e.g. `mcbot`) but need to execute commands as the Minecraft server user (e.g. `minecraft`) and manage the systemd service.

## Required sudoers entries

Create `/etc/sudoers.d/minecraft-management` with the following content.  
**Always edit sudoers with `sudo /usr/sbin/visudo -f /etc/sudoers.d/minecraft-management`.**

```
# ── Command aliases ────────────────────────────────────────────────────────────

# Game server instance(s) — add a line per instance if you have more than one
Cmnd_Alias MC_GAME_SERVER = \
    /usr/bin/systemctl start server.service, \
    /usr/bin/systemctl stop server.service, \
    /usr/bin/systemctl restart server.service, \
    /usr/bin/systemctl status server.service, \
    /usr/bin/systemctl enable server.service, \
    /usr/bin/systemctl disable server.service

# Support services (api-server, manager) — matched by prefix wildcard
Cmnd_Alias MC_SUPPORT_SERVICES = \
    /usr/bin/systemctl start minecraft-server-*.service, \
    /usr/bin/systemctl stop minecraft-server-*.service, \
    /usr/bin/systemctl restart minecraft-server-*.service, \
    /usr/bin/systemctl status minecraft-server-*.service, \
    /usr/bin/systemctl enable minecraft-server-*.service, \
    /usr/bin/systemctl disable minecraft-server-*.service

# Shared systemd and deployment commands
Cmnd_Alias MC_SYSTEMD = /usr/bin/systemctl daemon-reload
Cmnd_Alias MC_DEPLOY  = \
    /usr/bin/mv /tmp/minecraft-*.service /etc/systemd/system/, \
    /usr/bin/chmod 644 /etc/systemd/system/minecraft-*.service

# ── User grants ────────────────────────────────────────────────────────────────

# Allow the minecraft user to manage its own services
minecraft ALL=(root) NOPASSWD: MC_GAME_SERVER, MC_SUPPORT_SERVICES, MC_SYSTEMD

# Allow the application user to run management scripts as the minecraft user
mcbot ALL=(minecraft) NOPASSWD: /usr/bin/bash /home/minecraft/*/scripts/*/*

# Allow the application user to manage all Minecraft services
mcbot ALL=(root) NOPASSWD: MC_GAME_SERVER, MC_SUPPORT_SERVICES, MC_SYSTEMD, MC_DEPLOY
```

Replace `mcbot` and `minecraft` with your actual application and server users, and adjust service names if your instance is named differently.

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

- Each entry grants exactly one command on one service — no wildcards on service names.
- The `*/scripts/*/*` pattern restricts script execution to files inside any instance's `scripts/` directory.
- Never grant `ALL=(minecraft) NOPASSWD: ALL` — that gives unlimited shell access as the MC user.
- `visudo` validates syntax before writing; a malformed sudoers file can lock you out of `sudo` entirely, so always use it instead of editing the file directly.