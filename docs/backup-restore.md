# Backup, restore and rollback

How `backup/backup.sh`, `backup/restore.sh` and `rollback.sh` treat your data, and what they refuse to do.

## Backup

`backup/backup.sh [--archive [type]] [--dry-run] [--verbose]` stages the server directory, compresses it with `tar | zstd` and verifies the result.

- **One backup per instance at a time.** The script takes a non-blocking `flock` on `$BACKUPS_PATH/.backup.lock`. A second run (cron plus a wrapper-triggered one, for example) exits with status `75` without touching anything. `run_backup.sh` treats `75` as a skip and leaves that day's flag unset so the slot is retried.
- **Archive type.** `--archive <type>` must match `^[a-z0-9_-]+$`; anything else is rejected before any directory is created. Without a type, `general` is used.
- **Verification.** A failed `tar` or `zstd` in the pipeline fails the backup. The finished file must pass `zstd -t` and a full `tar -tf` listing. A failed backup never leaves a partial archive or the `tmp_backup` staging directory behind.
- **`DO_GENERATION_BACKUPS`** in `variables.txt` is compared with the string `true`; any other value means hourly backups only.

## Restore

`backup/restore.sh [--y] [--file <path> | --ago <duration>] [--archive]`

- **The server must be stopped.** The script checks live (RCON, the screen session and `systemctl is-active`, nothing cached) and exits with status `3` if the server is running or if none of those checks can be made. It checks again after extraction, immediately before the swap.
- **`--file`** takes either an absolute path or a name relative to `hourly/` (`archives/` with `--archive`). The resolved real path must be a regular file inside `$BACKUPS_PATH`: `..` segments are rejected, and symlinks that point outside the backups root are rejected. The API wrapper passes absolute paths.
- **Safe replacement.** The archive is validated (`zstd -t` and `tar -t`), extracted into a staging directory next to the server directory (`<server>.restore-staging.<pid>`), and swapped in by rename. If validation, extraction or the swap fails, the current server directory is left as it was. Dotfiles are replaced along with everything else.
- The staging directory must be on the same filesystem as the server directory, so a server directory that is itself a mount point cannot be restored this way.

## Rollback

`rollback.sh [--y] [--list]` restores the newest archive in `archives/update/`.

1. The archive is validated before anything is stopped, so a bad archive costs no downtime.
2. The server is stopped with `systemctl stop`. If that fails, or the server is still running afterwards, the rollback aborts with the files untouched.
3. The archive is extracted to staging, the server state is checked again, and the directory is swapped in.
4. If extraction or the swap fails, the server is started again with its original files.

## API wrapper

`POST /instances/:id/backups/files/:fileId/restore` answers `409` unless a fresh health probe reports the server `offline`, and `503` if that probe cannot complete. See the wrapper's `openapi.yaml`.

## Tests

`bash tests/shell/run.sh` exercises all three scripts against a scratch fake instance with fake `tar`, `zstd`, `rsync`, `systemctl`, `screen`, `sudo` and `flock` on `PATH`. It never touches real server data or systemd. Cases that need real symlinks or a real `flock` skip themselves with a message on hosts that lack them (for example Windows Git Bash).
