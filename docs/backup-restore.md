# Backup, restore and rollback

How `backup/backup.sh`, `backup/restore.sh` and `rollback.sh` treat your data, and what they refuse to do.

## Backup

`backup/backup.sh [--archive [type]] [--dry-run] [--verbose]` stages the server directory, compresses it with `tar | zstd` and verifies the result.

- **One backup per instance at a time.** The script takes a non-blocking `flock` on `$BACKUPS_PATH/.backup.lock`. A second run (cron plus a wrapper-triggered one, for example) exits with status `75` without touching anything. `run_backup.sh` treats `75` as a skip and leaves that day's flag unset so the slot is retried. On a host without `flock` the script logs a warning and runs unlocked.
- **Archive type.** `--archive <type>` must match `^[a-z0-9_-]+$`; anything else is rejected before any directory is created. Without a type, `general` is used.
- **Verification.** A failed `tar` or `zstd` in the pipeline fails the backup. The finished file must pass `zstd -t` and a full `tar -tf` listing. A failed backup never leaves a partial archive or the `tmp_backup` staging directory behind.
- **`DO_GENERATION_BACKUPS`** in `variables.txt` is compared with the string `true`; any other value means hourly backups only.
- **Private by default.** Archives contain `common/variables.txt` (API key, RCON password, webhook URL) and `api-server-config.json`, so the script runs under `umask 077`: archives and the staging directory are readable by the instance user only. Set `BACKUP_UMASK` (for example `027`) in the environment of the backup job if another account, such as an API wrapper running as a different user, must read the archives. The standard setup runs the wrapper as the same user.
- **Notifications.** The webhook request is bounded (`--max-time 10`, `-f`), the URL is passed to `curl` on stdin so it never shows in the process list, and the script waits for in-flight notifications before it exits.

## Locks

`maintenance.sh` and `message_onjoin.sh` take a per-instance lock through `acquire_instance_lock` in `src/scripts/common/utils.sh`; a second copy for the same instance exits with a message. The lock file lives in a private directory (mode `700`), chosen in this order: `INSTANCE_LOCK_DIR`, `$XDG_RUNTIME_DIR/minecraft`, then `scripts/.locks`. It is never placed in the world-writable `/tmp`. With `flock` the lock is released by the kernel when the process dies, so a crashed run cannot strand it. Without `flock` the helper falls back to a `mkdir` lock that records the owner's pid and is taken over when that process is gone. Set `INSTANCE_LOCK_DIR` in the environment of the script (for example in the systemd unit) to move the lock directory.

## Cleanup

`backup/automation/cleanup_backups.sh` applies the retention policy.

- **Count caps.** `MAX_HOURLY_BACKUPS`, `MAX_DAILY_BACKUPS`, `MAX_WEEKLY_BACKUPS` and `MAX_MONTHLY_BACKUPS` keep the newest N of each tier. `MAX_UPDATE_BACKUPS` (default `5`, optional `BACKUPS.MAX_UPDATE_BACKUPS` in `variables.json`) does the same for `archives/update/`, the rollback targets.
- **Storage limit.** Above `MAX_STORAGE_GB` the script evicts oldest-first within a tier, tier by tier: hourly, daily, weekly, update, then monthly. A monthly archive is only evicted once nothing else is left.
- **Jars.** Archives link to the jars stored once under `jars/`. A jar that no remaining archive references and that is older than a day is deleted. If any archive cannot be listed, no jar is deleted.
- **A file that cannot be deleted** is reported and skipped; the rest of the run continues.

## Restore

`backup/restore.sh [--y] [--file <path> | --ago <duration>] [--archive]`

- **The server must be stopped.** The script checks live (RCON, the screen session and `systemctl is-active`, nothing cached) and exits with status `3` if the server is running or if none of those checks can be made. It checks again after extraction, immediately before the swap.
- **`--file`** takes either an absolute path or a name relative to `hourly/` (`archives/` with `--archive`). The resolved real path must be a regular file inside `$BACKUPS_PATH`: `..` segments are rejected, and symlinks that point outside the backups root are rejected. The API wrapper passes absolute paths.
- **Safe replacement.** The archive is validated (`zstd -t` and `tar -t`), extracted into a staging directory next to the server directory (`<server>.restore-staging.<pid>`), and swapped in by rename. If validation, extraction or the swap fails, the current server directory is left as it was. Dotfiles are replaced along with everything else.
- **Systemd units in an archive are never installed silently.** Archive backups carry the instance's unit files. A restore prints how each one differs from the installed unit (or its full contents when new) and installs it with `sudo` only when you pass `--install-units` or answer `y` at an interactive prompt. A non-interactive run, which includes the API wrapper's restore, skips the units and says so; install them afterwards by hand or rerun with `--install-units`. `daemon-reload` runs only after a unit was installed. `SYSTEMD_UNIT_DIR` (default `/etc/systemd/system`) overrides the target directory.
- The staging directory must be on the same filesystem as the server directory, so a server directory that is itself a mount point cannot be restored this way.

## Rollback

`rollback.sh [--y] [--list]` restores the newest archive in `archives/update/`.

1. The archive is validated before anything is stopped, so a bad archive costs no downtime.
2. The server is stopped with `systemctl stop`. If that fails, or the server is still running afterwards, the rollback aborts with the files untouched.
3. The archive is extracted to staging, the server state is checked again, and the directory is swapped in.
4. If extraction or the swap fails, the server is started again with its original files.

## API wrapper

`POST /instances/:id/backups/files/:fileId/restore` answers `409` unless a fresh health probe reports the server `offline`, and `503` if that probe cannot complete. See the wrapper's `openapi.json`.

## Downloads

The Node update scripts (`src/scripts/update/lib/download.js`) treat everything a remote API names as untrusted. A download goes to `<target>.tmp` first and is renamed into place only after it passed its checks, so a failed or rejected download leaves no partial file behind. `add-mod.js` and `update-mods.js` verify the sha512 that Modrinth publishes, `update-server.js` verifies the sha1 that Mojang publishes. The file name is taken from the URL, percent-decoded and then required to be a single plain name, so a hostile URL cannot write outside `mods/`. Bodies are capped (512 MiB by default) and bounded by a response timeout and an overall deadline.

## Tests

`bash tests/shell/run.sh` exercises the backup, restore, rollback, cleanup, webhook and server-control scripts and the Node update scripts (`tests/js`, with a stubbed `axios`) against a scratch fake instance with fake `tar`, `zstd`, `rsync`, `systemctl`, `screen`, `sudo` and `flock` on `PATH`. It never touches real server data or systemd. Cases that need real symlinks or a real `flock` skip themselves with a message on hosts that lack them (for example Windows Git Bash).
