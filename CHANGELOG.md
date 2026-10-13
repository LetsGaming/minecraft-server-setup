# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- **A dedicated user for the API wrapper.** `API_SERVER.SERVICE_USER` (or `src/setup/management/service_user.sh` by hand) creates an unprivileged system user for the wrapper, grants it with ACLs read on the instance, scripts, backups and wrapper folders and write only on the config folders, `server.properties`, the config snapshot folder, `world/stats` and the backup folders, and writes a validated sudoers file that names the exact scripts, `systemctl` actions and `screen` commands it may run. Adds `UMask=0002` to the instance's unit. See `docs/service-user.md`.

- `update/upgrade.sh <version>` and `upgrade-server.js`: the whole version upgrade as one job (plan check, countdown, stop, archive backup, install, start and watch). If the first start fails the mods without a build for the target are disabled and it starts again; if that fails too, this job's own backup is restored. Progress is NDJSON. See `docs/upgrade.md`.
- `update-server.js --plan`, `--apply`, `--json`, `--yes`, `--keep-incompatible`.
- `start.sh` writes lifecycle events (`jvm_start`, `jvm_exit`, `restart_scheduled`, `crash_loop_gave_up`) to `logs/lifecycle.ndjson` and sends a `server_crash_loop` webhook when it gives up. Restart behaviour is unchanged.
- `acquire_operation_lock` in `common/utils.sh`: one slot per instance for restore, rollback, backup and upgrade; a refused run exits `75`.
- `common/instance_ops.sh`: announce, stop, halt, start, running and notify as small commands.

- `world/prune-chunks.js`: delete generated chunks nobody has used (InhabitedTime below a threshold) so a new Minecraft version regenerates them. Spawn, player positions, drawn zones and a buffer are never touched; region, entities and poi are pruned together; `--scan` is read only, `--apply` re-scans and deletes only what both scans agree on. `upgrade.sh --prune-plan=<id>` runs it inside an upgrade; `--prune-only` runs it alone, both under one backup. See `docs/chunk-pruning.md`.

- **Server-side migrations in `migrate.sh`** (`src/migrations/server.sh`, `docs/migrations.md`). Until now `migrate.sh` only updated the helper scripts and shared services; the files the suite wrote for the server itself never reached existing installs. `instance_start_script` updates `<instance>/start.sh` (old copy kept, takes effect at the next start) and `unit_start_limits` adds crash-loop limits to the instance's systemd unit (daemon-reload, no restart). Detected from the real files, previewed, idempotent, recorded in `common/server-migrations.log`, never restarts the server. New options `--list-server-migrations` and `--no-server-migrations`.

### Changed

- `prune-chunks.js --scan` reads regions on worker threads into a per-region record cache and prints NDJSON progress. A repeat scan takes about a tenth of the time, changing a threshold, radius, buffer or zone reads no region file, and `--apply` reads only the regions it deletes from (in parallel). Options `--workers` and `--no-cache`.
- `update-server.js` records the new version after the jar swap instead of before it, and disables incompatible mods (reversible, `mods/disabled/`) instead of deleting jars by filename match.
- `backup.sh`, `restore.sh` and `rollback.sh` take the operation lock, so they no longer overlap with each other or with an upgrade.

### Fixed

- A world with regions very far apart no longer fails a prune scan with a buffer; the buffer is computed per region.
- `prune-chunks.js --apply`: a chunk that was already corrupt no longer makes the post-prune check fail and roll the whole job back; the check now compares kept chunks byte for byte instead of re-reading them.
- `prune-chunks.js --apply` refuses to run when `instance_ops.sh` is missing (it used to assume the server was stopped), takes the operation lock when run by hand, rejects a plan whose content does not match its hash, and deletes only in folders found by the fresh scan.
- Region files with a chunk entry of zero sectors or overlapping sectors are left untouched by a prune instead of being rewritten.
- A negative array length in chunk data is rejected instead of looping.
- `prune-chunks.js --scan --params={}` uses the saved settings, as the dashboard expects.
- `prune-chunks.js --scan --profile` and `tests/bench/bench-prune.cjs` report where scan time goes.

## [5.0.0] - 2026-10-10

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

