# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `.github/workflows/wrapper-contract.yml`: builds the API wrapper commit the `src/scripts/api-server` submodule pins and runs the bot's `e2e:contract` against it, on every pointer change.
- `docs/wrapper-submodule.md`: the order of a contract change (wrapper, this pointer, bot), the compatibility window, and how to bump the submodule pointer.
- `tests/shell/`: plain-bash tests for `backup.sh`, `restore.sh` and `rollback.sh` using fake binaries on `PATH`. Run with `bash tests/shell/run.sh`.
- `docs/backup-restore.md`: restore, rollback and backup semantics.

### Changed

- `restore.sh` refuses to run (exit 3) while the server is running or when that cannot be determined, and re-checks right before replacing the server directory.
- `restore.sh --file` accepts an absolute path inside `$BACKUPS_PATH` (the form the API wrapper sends); `..` and symlinks leaving the backups root are rejected. Tier-relative names still work.
- `backup.sh` takes a per-instance lock (`$BACKUPS_PATH/.backup.lock`) and exits `75` when another backup is running; `run_backup.sh` treats that as a skip.

### Fixed

- `restore.sh` and `rollback.sh` deleted the server files before reading the archive, so a corrupt archive or failed extraction lost the world, and dotfiles were left behind. Archives are now validated, extracted to a staging directory and swapped in; failures leave the current files untouched.
- `rollback.sh` kept going when `systemctl stop` failed, and could not run at all because `common/webhook.sh` read an unset variable under `set -u`.
- `restore.sh --ago` selected a path with the timestamp column still attached and never found a backup.
- `restore.sh --file` / `--ago` without a value now print a usage error instead of an unbound-variable failure.
- `backup.sh` reported success when `tar` died midway through the `tar | zstd` pipeline. The archive is now verified with `zstd -t` and `tar -tf`, and a failed run removes its partial archive and `tmp_backup` directory.
- The failure path in `backup.sh` aborted before removing a corrupt archive when the server was offline.

### Security

- `backup.sh --archive <type>` is limited to `^[a-z0-9_-]+$`, so `..` can no longer redirect backups outside `archives/`.
- `run_backup.sh` compares `DO_GENERATION_BACKUPS` as a string instead of executing it as a command.
