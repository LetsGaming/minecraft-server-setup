# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `.github/workflows/wrapper-contract.yml`: builds the API wrapper commit the `src/scripts/api-server` submodule pins and runs the bot's `e2e:contract` against it, on every pointer change.
- `docs/wrapper-submodule.md`: the order of a contract change (wrapper, this pointer, bot), the compatibility window, and how to bump the submodule pointer.
- `MAX_UPDATE_BACKUPS` (default `5`, optional `BACKUPS.MAX_UPDATE_BACKUPS` in `variables.json`) caps `archives/update/` in `cleanup_backups.sh`.
- `restore.sh --install-units` and `SYSTEMD_UNIT_DIR`: units stored in an archive are installed only after a printed diff and explicit consent.
- `BACKUP_UMASK` (default `077`) for `backup.sh`.
- `common/webhook.sh`: `wait_for_notifications`.
- `common/utils.sh`: `acquire_instance_lock` / `release_instance_lock`, a per-instance `flock` lock (with a `mkdir` fallback) in a private directory.
- `update/lib/`: shared `variables.js`, `jars.js`, `json-mode.js` and `download.js`; `lib/args.js` honours a bare `--`.
- `check-updates.js` reports `downloadSha512` for each available update.
- `docs/sudoers-setup.md` documents the `node` grant the API wrapper's mod operations need and the `MC_BASH_PATH` / `MC_NODE_PATH` pinning.
- `tests/js/`: Node tests for the update scripts (stubbed `axios`), run by `tests/shell/run.sh`.
- `tests/shell/`: plain-bash tests for `backup.sh`, `restore.sh` and `rollback.sh` using fake binaries on `PATH`. Run with `bash tests/shell/run.sh`.
- `docs/backup-restore.md`: restore, rollback and backup semantics.

### Changed

- `cleanup_backups.sh` evicts by tier when over `MAX_STORAGE_GB`: hourly, daily, weekly, update, then monthly (oldest first within a tier). It used to evict the oldest file of any tier, monthly archives included.
- `restore.sh` no longer copies systemd units from an archive with `sudo` unprompted; a non-interactive run (the API wrapper's restore) now skips them with a notice.
- `.claude-flow/` is no longer tracked.
- `variables.json` validation and `--check` reject an `API_SERVER.API_KEY` shorter than 32 characters, matching the API wrapper, which refuses to start with one.

- `restore.sh` refuses to run (exit 3) while the server is running or when that cannot be determined, and re-checks right before replacing the server directory.
- `restore.sh --file` accepts an absolute path inside `$BACKUPS_PATH` (the form the API wrapper sends); `..` and symlinks leaving the backups root are rejected. Tier-relative names still work.
- `backup.sh` takes a per-instance lock (`$BACKUPS_PATH/.backup.lock`) and exits `75` when another backup is running; `run_backup.sh` treats that as a skip.

### Fixed

- `maintenance.sh` replaced its lock-removal `EXIT` trap with the cleanup trap, so the `/tmp` lock was never removed and later runs reported "already running". `maintenance.sh` and `message_onjoin.sh` now share a per-instance lock that cannot be stranded.
- `save_and_wait` started watching the log after sending `save-all`, so a fast save was missed and the wait timed out; it now records the log offset first. Waiting no longer spawns a `tail -f` (which leaked on timeout) or interpolates the log path into `bash -c`.
- `session_running` matched the instance name as a substring (`mc` matched `mc2`); it now matches `<pid>.<name>` exactly.
- `countdown` leaked its loop variable `i` into the caller.
- `smart_restart.sh --warn` and `RESTART_WARN_SECONDS` are validated as whole numbers.
- `cleanup_backups.sh` aborted on the first file it could not delete, never pruned `archives/update/` or `jars/`.
- `add-mod.js`, `update-mods.js`: the download filename was decoded after `basename`, so `%2F..%2F` in a hostile URL became a path outside `mods/`. Downloads now go through a temp file with a timeout and size cap, are verified against Modrinth's sha512, and leave no `.tmp` file on failure.
- `update-server.js` wrote the vanilla `server.jar` in place with no integrity check; it now downloads to a temp file, verifies Mojang's sha1 and renames.
- `webhook.sh` sent notifications with a background `curl` that had no timeout or failure flag and put the webhook URL (a secret) in the process list.
- `remove-mod.js --json` no longer emits an always-empty `orphanedDependencies`.

- `restore.sh` and `rollback.sh` deleted the server files before reading the archive, so a corrupt archive or failed extraction lost the world, and dotfiles were left behind. Archives are now validated, extracted to a staging directory and swapped in; failures leave the current files untouched.
- `rollback.sh` kept going when `systemctl stop` failed, and could not run at all because `common/webhook.sh` read an unset variable under `set -u`.
- `restore.sh --ago` selected a path with the timestamp column still attached and never found a backup.
- `restore.sh --file` / `--ago` without a value now print a usage error instead of an unbound-variable failure.
- `backup.sh` reported success when `tar` died midway through the `tar | zstd` pipeline. The archive is now verified with `zstd -t` and `tar -tf`, and a failed run removes its partial archive and `tmp_backup` directory.
- The failure path in `backup.sh` aborted before removing a corrupt archive when the server was offline.

### Security

- `backup.sh` creates archives (which contain `variables.txt` and the API config) under `umask 077`.
- `restore.sh` writes the restored `api-server-config.json` with mode `600`.

- `backup.sh --archive <type>` is limited to `^[a-z0-9_-]+$`, so `..` can no longer redirect backups outside `archives/`.
- `run_backup.sh` compares `DO_GENERATION_BACKUPS` as a string instead of executing it as a command.
