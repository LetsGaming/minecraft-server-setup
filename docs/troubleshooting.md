# Troubleshooting

Start with the read-only health check. It reports what is wrong with an installed instance without changing anything:

```bash
sudo bash manage.sh doctor              # every instance
sudo bash manage.sh doctor survival     # one instance
```

For problems before an install, `bash main.sh --check` validates `variables.json`, the required tools, Node.js and disk space, then exits.

## Friends cannot connect

Check these in order:

1. **The server is running.** `systemctl status <instance>` and `screen -ls` (run as the server's user).
2. **The host firewall allows the port.** Setup does not touch your firewall. With UFW:

   ```bash
   sudo ufw allow 25565/tcp     # use JAVA.SERVER.PORT if you changed it
   sudo ufw status
   ```

3. **The port is the one you expect.** Setup uses 25565 unless it was already in use, then picks the next free port and prints it. The value is `server-port` in `server.properties`.
4. **Friends outside your network** also need router port forwarding (TCP, same port) and your public address. See [Reaching your server from outside your network](../readme.md#reaching-your-server-from-outside-your-network).

## Node.js is missing or too old

Setup needs Node.js 18 or newer. It uses an installed Node 18+ as is, otherwise installs the distribution's own `nodejs` package when that is 18+.

On releases whose package is older (Ubuntu 22.04, Debian 11) Node 22 would have to come from the third-party NodeSource apt repository. Setup only does that when you opt in:

```bash
bash main.sh --allow-nodesource
```

Without the flag setup stops and prints the manual commands. Then run setup again.

## Setup stopped halfway

A failed install keeps its `variables.json`. Run `bash main.sh` again to retry with the same choices, or delete the file to start over. Setup never overwrites an existing instance: a taken name falls back to `server-2`, `server-3`, and so on.

`variables.json` must be strict JSON (no comments, no trailing commas). A parse error at the start of a run is almost always that.

## Backups

**Disk is filling up.** Backups are capped by `BACKUPS.MAX_STORAGE_GB` and by per-tier counts. When usage goes above the storage limit, cleanup evicts the oldest archives that may be evicted. If it still ends above the limit it logs a warning and sends a `storage_warning` webhook event. Lower the limit or the retention counts, or point `BACKUPS.BACKUPS_PATH` at a larger disk. A count of `0` keeps every backup of that tier, and only the storage limit then applies.

**A backup looks corrupt.** Restore and rollback validate the archive before touching the server. Details and the restore steps are in [backup-restore.md](backup-restore.md).

## The service keeps failing to start

The unit gives up after 5 failed starts within 2 minutes (`StartLimitIntervalSec=120`, `StartLimitBurst=5`), so a broken server (a bad mod, a wrong Java version) does not restart forever. Read the cause first:

```bash
journalctl -u <instance> -n 100 --no-pager
```

After fixing it, clear the failure state and start again:

```bash
sudo systemctl reset-failed <instance> && sudo systemctl start <instance>
```

## Still stuck

Run `manage.sh doctor` and `main.sh --check`, then open an issue with their output. Remove secrets (RCON password, API key, webhook URL) before pasting.
