# Sudoers Configuration

> The suite can create the application user and write these rules for you: see [service-user.md](service-user.md). The hand-written rules below remain valid for installs that run the wrapper as another existing user.

The setup and management scripts run as a non-root application user (e.g. `mcbot`) but need to execute commands as the Minecraft server user (e.g. `minecraft`) and manage the systemd service.

## Required sudoers entries

Create `/etc/sudoers.d/minecraft-management` with the following content.
**Always edit sudoers with `sudo /usr/sbin/visudo -f /etc/sudoers.d/minecraft-management`.**

The example is for an install at `/home/minecraft/mc` with one instance named `survival`, run by the `minecraft` user, and the wrapper running as `mcbot`. Replace every path and name with yours; one block per instance. These are the same rules `service_user.sh --print-sudoers` generates.

```
# Alias names must be upper case, or visudo rejects the file.

# The runtime unit actions, for this instance only. reset-failed clears a
# crash-loop-tripped `failed` state; show is read-only (the health probe reads
# NRestarts and ActiveState). enable, disable, daemon-reload and installing
# units are setup steps an admin runs with their own sudo.
Cmnd_Alias MC_SURVIVAL_UNIT = \
    /usr/bin/systemctl start survival.service, \
    /usr/bin/systemctl stop survival.service, \
    /usr/bin/systemctl restart survival.service, \
    /usr/bin/systemctl status survival.service, \
    /usr/bin/systemctl reset-failed survival.service, \
    /usr/bin/systemctl show survival.service *

# The scripts the wrapper runs, each with exactly the arguments it passes.
# A script named without arguments may only run without arguments.
Cmnd_Alias MC_SURVIVAL_SCRIPTS = \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/start.sh, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/shutdown.sh, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/smart_restart.sh, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/misc/status.sh, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/rollback.sh, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/rollback.sh --y, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/backup/backup.sh, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/backup/backup.sh --archive, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/backup/restore.sh --file /home/minecraft/mc/backups/survival/* --y, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/backup/restore.sh --y --archive --file /home/minecraft/mc/backups/survival/*, \
    /usr/bin/bash /home/minecraft/mc/scripts/survival/update/upgrade.sh *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/world/prune-chunks.js *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/update/add-mod.js *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/update/remove-mod.js *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/update/update-mod.js *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/update/update-mods.js *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/update/check-updates.js *, \
    /usr/bin/node /home/minecraft/mc/scripts/survival/update/toggle-mod.js *

# Console input into this instance's screen session, and listing sessions.
Cmnd_Alias MC_SURVIVAL_SCREEN = \
    /usr/bin/screen -list, \
    /usr/bin/screen -S survival -X stuff *

mcbot ALL=(root) NOPASSWD: MC_SURVIVAL_UNIT
mcbot ALL=(minecraft) NOPASSWD: MC_SURVIVAL_SCRIPTS, MC_SURVIVAL_SCREEN
```

Replace `mcbot` and `minecraft` with your actual application and server users.

> **Changed in 5.x:** earlier versions of this page recommended
> `/usr/bin/bash /home/minecraft/*/scripts/*` and
> `systemctl stop minecraft-server-*.service`. Both are wider than they look.
> In a command's *arguments* a sudoers `*` matches `/` and spaces, so the first
> matches `bash /home/minecraft/x/scripts/../../../tmp/evil.sh`, any script on
> the machine; the second matches `systemctl stop minecraft-server-a.service
> sshd.service`, any unit as root. Replace them with the rules above.

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

## Service names

The game server's unit is named after the instance (`survival.service` above). The API wrapper's unit is `<install folder>-api-server.service`; it is managed by the admin, not by the wrapper, so it needs no grant here.

## Verifying the configuration

After saving, verify each user can run their commands without a password:

```bash
# As mcbot: list what it may run, then try a harmless one
sudo -l
sudo -n systemctl status survival.service
sudo -n -u minecraft /usr/bin/node /home/minecraft/mc/scripts/survival/update/check-updates.js --json --
```

If either command asks for a password, the sudoers entry is not applied correctly.

## Principle of least privilege

- Only the runtime actions (`start`/`stop`/`restart`/`status`, plus `reset-failed` and the read-only `show`) are granted, for the instance's own unit. `enable`, `disable`, `daemon-reload` and unit-file creation are **setup-time** operations performed by an admin's own sudo.
- Scripts are named one by one with the arguments the wrapper passes. A wildcard only ever follows a full script path, and only where the script checks what follows: restore refuses an archive outside the backups folder or one the server user did not make.
- **The scripts folder must be owned by `minecraft` and not writable by `mcbot`**, and `mcbot` must not be able to write anywhere the server loads code from (`plugins/`, `mods/`, the scripts). Otherwise these grants let it run anything as `minecraft`.
- Never grant `ALL=(minecraft) NOPASSWD: ALL`, or a bare `/usr/bin/screen`: `screen -dm bash -c …` is a shell.
- Never grant a `mv`/`cp`/`tee` from a world-writable location (e.g. `/tmp`) into `/etc/systemd/system/` — that is an arbitrary-root-unit install.
- `visudo` validates syntax before writing; a malformed sudoers file can lock you out of `sudo` entirely, so always use it instead of editing the file directly.
