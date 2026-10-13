# A dedicated user for the API wrapper

By default the API wrapper runs as the same Linux user as the Minecraft server, so it can
do everything that user can. `API_SERVER.SERVICE_USER` gives it its own unprivileged user
instead, with access to the server's files and nothing beyond what the wrapper needs.

The bot always runs in a container and always talks to this host through the wrapper, so
this user is the only account on the host that the network-facing side runs as.

## Turn it on

In `variables.json`:

```json
"API_SERVER": { "ENABLED": true, "PORT": 3030, "API_KEY": "...", "SERVICE_USER": "mcapi" }
```

`main.sh --api-server` then creates the user, grants access, deploys the wrapper and starts
it as that user. `setfacl` must be installed (`apt install acl`), and the filesystem must
support ACLs (ext4, xfs and btrfs do by default).

For an install that already exists, run the script by hand, once per instance:

```
sudo bash src/setup/management/service_user.sh \
  --scripts-dir /home/minecraft/minecraft-server/scripts/server --user mcapi
```

then set `User=mcapi` and `Group=mcapi` in the wrapper's unit (or delete the unit and run
`main.sh --api-server` again), `systemctl daemon-reload`, and restart it. Add
`--dry-run` to see every command first and `--print-sudoers` to see only the sudoers file.
It is safe to run again.

## What the user gets

| Access | Where | How |
|---|---|---|
| Traverse (`x`) | each folder from the install root up to `/` | ACL, no read |
| Read | the instance folder, the scripts folder, the backups folder, the wrapper's own folder and its config | ACL, recursive, with defaults so new files inherit it |
| Write | `config/`, `defaultconfigs/`, `world/serverconfig/`, `plugins/`, `server.properties`, `.mcbot-config-snapshots/`, `world/stats/` | ACL, recursive (the dashboard's config editor and the stats cleanup) |
| Write on folders only | every folder under the backups folder | lets it delete an archive; archives stay read-only |
| Run as the server user | the exact scripts the wrapper uses (start, stop, restart, rollback, backup, restore, status, upgrade, prune, the mod scripts), and `screen -list` and `screen -S <instance> -X stuff` | sudoers file, one per instance |
| Run as root | `systemctl start/stop/restart/status/reset-failed/show <instance>.service` | the same sudoers file |

Ownership is never changed; everything is an ACL entry for that one user. Nothing is granted
on the world, the mods or the jar beyond read, and nothing at all outside the install.

The sudoers file is `/etc/sudoers.d/mc-service-<user>-<instance>`. It is generated, checked
with `visudo -cf` before it is installed, and replaced when it differs. It names absolute
paths for `bash` and `node` (the same ones the wrapper is pinned to with `MC_BASH_PATH` and
`MC_NODE_PATH`) and contains no wildcard in a script path. Do not edit it; run the script
again.

## What it changes in the instance's unit

`UMask=0002` is added under `[Service]` (the old unit is kept as
`<instance>.service.pre-service-user`, and it takes effect at the next server start). New
files the server creates then keep the write bit that the ACL mask needs, so a mod's
freshly created config file is editable from the dashboard. The server's own group has one
member, so this exposes nothing to other users.

## What it does not do

- **No sandbox for the wrapper.** The wrapper starts scripts through `sudo`, and systemd
  hardening such as `NoNewPrivileges`, `ProtectSystem` or `ProtectHome` would either block
  `sudo` or make the scripts it starts read-only too. The boundary is the user, the ACLs and
  the sudoers file, not the unit.
- **The scripts must stay unwritable by the service user.** The sudoers rules let it run
  them as the server user. The script never grants write on the scripts folder; do not add
  it.
- **The server's secrets are readable.** `server.properties` (including the RCON password)
  and the wrapper's config are readable by the service user, because the wrapper needs them.
- **Root is needed once** to create the user and the sudoers file. The wrapper itself never
  has it beyond the `systemctl` rules above.

## Undo

```
sudo rm /etc/sudoers.d/mc-service-mcapi-<instance>
sudo setfacl -R -x u:mcapi <instance folder> <scripts folder> <backups folder> <wrapper folder>
sudo userdel mcapi
```

and point the wrapper's unit back at the old user.
