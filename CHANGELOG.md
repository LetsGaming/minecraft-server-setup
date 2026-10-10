# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

Items marked **BREAKING** change behaviour that scripts, cron jobs or the API wrapper may rely on.

### Added

- `docs/backup-restore.md`: what backup, restore, rollback and cleanup do and refuse to do, plus locks and verified downloads.
- `docs/wrapper-submodule.md`: the order of a contract change (wrapper, this pointer, bot), the compatibility window, and how to bump the submodule pointer.
- `.github/workflows/wrapper-contract.yml`: builds the API wrapper commit the `src/scripts/api-server` submodule pins and runs the bot's `e2e:contract` against it, on every pointer change.
- `restore.sh --install-units` and `SYSTEMD_UNIT_DIR`: units stored in an archive are installed only after a printed diff and explicit consent.
- `MAX_UPDATE_BACKUPS` (default `5`, optional `BACKUPS.MAX_UPDATE_BACKUPS` in `variables.json`) caps `archives/update/` in `cleanup_backups.sh`, which now also prunes orphaned jars.
- `BACKUP_UMASK` (default `077`) for `backup.sh`.
- `INSTANCE_LOCK_DIR` and `acquire_instance_lock` / `release_instance_lock` in `common/utils.sh`: a per-instance `flock` lock (with a `mkdir` fallback) in a private directory, used by `maintenance.sh` and `message_onjoin.sh`.
- `backup.sh` takes a per-instance lock (`$BACKUPS_PATH/.backup.lock`) and exits `75` when another backup is running; `run_backup.sh` treats that as a skip.
- `common/webhook.sh`: `wait_for_notifications`.
- `update/lib/`: shared `variables.js`, `jars.js`, `json-mode.js` and `download.js`; `lib/args.js` honours a bare `--`.
- `check-updates.js --only=<slug>` checks a single installed mod (default behaviour and JSON shape unchanged); the API wrapper uses it for the mod compatibility check. `check-updates.js` also reports `downloadSha512` for each available update.
- `docs/sudoers-setup.md` documents the `node` grant the API wrapper's mod operations need and the `MC_BASH_PATH` / `MC_NODE_PATH` pinning.
- `tests/shell/` (plain-bash tests for backup, restore, rollback, cleanup, webhook and server control, using fake binaries on `PATH`) and `tests/js/` (Node tests for the update scripts with a stubbed `axios`), both run by `bash tests/shell/run.sh`.

### Changed

- **BREAKING: `restore.sh` refuses to run (exit 3) while the server is running or when that cannot be determined.** It re-checks right before replacing the server directory. Stop the server first; the API wrapper's restore route enforces the same rule.
- **BREAKING: `restore.sh` no longer copies systemd units from an archive with `sudo` unprompted.** It prints how each unit differs and installs it only with `--install-units` or an interactive `y`; a non-interactive run (the API wrapper's restore) skips the units with a notice.
- **BREAKING: `variables.json` validation and `--check` reject an `API_SERVER.API_KEY` shorter than 32 characters**, matching the API wrapper, which refuses to start with one.
- **BREAKING: `backup.sh --archive <type>` is limited to `^[a-z0-9_-]+$`.** Other values are rejected before anything is created.
- **BREAKING: `remove-mod.js --json` no longer emits `orphanedDependencies`**; it was always empty.
- `restore.sh --file` accepts an absolute path inside `$BACKUPS_PATH` (the form the API wrapper sends); `..` and symlinks leaving the backups root are rejected. Tier-relative names still work.
- `cleanup_backups.sh` evicts by tier when over `MAX_STORAGE_GB`: hourly, daily, weekly, update, then monthly (oldest first within a tier). It used to evict the oldest file of any tier, monthly archives included.
- `.claude-flow/` is no longer tracked.

### Security

- **BREAKING for readers other than the instance user:** `backup.sh` creates archives (which contain `variables.txt` and the API config) under `umask 077`. Set `BACKUP_UMASK` to widen it.
- `restore.sh` writes the restored `api-server-config.json` with mode `600`.
- `add-mod.js`, `update-mods.js`: the download filename was decoded after `basename`, so `%2F..%2F` in a hostile URL became a path outside `mods/`. Downloads now go through a temp file with a timeout and size cap, are verified against Modrinth's sha512, and leave no `.tmp` file on failure.
- `update-server.js` wrote the vanilla `server.jar` in place with no integrity check; it now downloads to a temp file, verifies Mojang's sha1 and renames.
- `webhook.sh` sent notifications with a background `curl` that had no timeout or failure flag and put the webhook URL (a secret) in the process list. The request is now bounded and the URL is passed on stdin.
- `run_backup.sh` compares `DO_GENERATION_BACKUPS` as a string instead of executing it as a command.
- Lock files no longer live in the world-writable `/tmp` (see `INSTANCE_LOCK_DIR`).

### Fixed

- `restore.sh` and `rollback.sh` deleted the server files before reading the archive, so a corrupt archive or failed extraction lost the world, and dotfiles were left behind. Archives are now validated, extracted to a staging directory and swapped in; failures leave the current files untouched.
- `rollback.sh` kept going when `systemctl stop` failed, and could not run at all because `common/webhook.sh` read an unset variable under `set -u`.
- `restore.sh --ago` selected a path with the timestamp column still attached and never found a backup. `--file` / `--ago` without a value now print a usage error instead of an unbound-variable failure.
- `backup.sh` reported success when `tar` died midway through the `tar | zstd` pipeline. The archive is now verified with `zstd -t` and `tar -tf`, and a failed run removes its partial archive and `tmp_backup` directory, also when the server is offline.
- `maintenance.sh` replaced its lock-removal `EXIT` trap with the cleanup trap, so the `/tmp` lock was never removed and later runs reported "already running".
- `save_and_wait` started watching the log after sending `save-all`, so a fast save was missed and the wait timed out; it now records the log offset first. Waiting no longer spawns a `tail -f` (which leaked on timeout) or interpolates the log path into `bash -c`.
- `session_running` matched the instance name as a substring (`mc` matched `mc2`); it now matches `<pid>.<name>` exactly.
- `countdown` leaked its loop variable `i` into the caller. `smart_restart.sh --warn` and `RESTART_WARN_SECONDS` are validated as whole numbers.
- `cleanup_backups.sh` aborted on the first file it could not delete and never pruned `archives/update/` or `jars/`; it now reports the file and continues.

