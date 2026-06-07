# Sudoers Configuration

The setup and management scripts run as a non-root application user (e.g. `mcbot`) but need to execute commands as the Minecraft server user (e.g. `minecraft`) and manage the systemd service.

## Required sudoers entries

Create `/etc/sudoers.d/minecraft-management` with the following content.  
**Always edit sudoers with `visudo -f /etc/sudoers.d/minecraft-management`.**

```
# Allow the application user to switch to the MC user and run management scripts
mcbot ALL=(minecraft) NOPASSWD: /usr/bin/bash /home/minecraft/*/scripts/*/*

# Allow the application user to manage the Minecraft systemd services
mcbot ALL=(root) NOPASSWD: /bin/systemctl start minecraft-*
mcbot ALL=(root) NOPASSWD: /bin/systemctl stop minecraft-*
mcbot ALL=(root) NOPASSWD: /bin/systemctl restart minecraft-*
mcbot ALL=(root) NOPASSWD: /bin/systemctl status minecraft-*
mcbot ALL=(root) NOPASSWD: /bin/systemctl enable minecraft-*
mcbot ALL=(root) NOPASSWD: /bin/systemctl disable minecraft-*
mcbot ALL=(root) NOPASSWD: /bin/systemctl daemon-reload
mcbot ALL=(root) NOPASSWD: /bin/mv /tmp/minecraft-*.service /etc/systemd/system/
mcbot ALL=(root) NOPASSWD: /bin/chmod 644 /etc/systemd/system/minecraft-*.service
```

Replace `mcbot` with your actual application user and adjust paths as needed.

## Verifying the configuration

After saving, test that the `-n` flag (non-interactive) works:

```bash
sudo -n -u minecraft echo "ok"
sudo -n systemctl status minecraft-survival.service
```

If either command asks for a password, the sudoers entry is not applied correctly.

## Principle of least privilege

The wildcard `*/scripts/*/*` restricts `sudo` to scripts inside any instance's `scripts/` directory. Never grant `ALL=(minecraft) NOPASSWD: ALL` — that gives unlimited shell access as the MC user.
