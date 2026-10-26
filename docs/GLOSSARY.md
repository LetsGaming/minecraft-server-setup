# Glossary

Terms specific to this project that are easy to misread.

**Operation lock.** The one slot per instance for work that rewrites the server or its archives: restore, rollback, backup, upgrade, backup cleanup and the mod scripts. It is a file under `scripts/<instance>/.locks` (or `INSTANCE_LOCK_DIR`), taken with `flock`, or with a `mkdir` lock where `flock` is missing. A refused run exits `75`. The holder exports `MC_OPERATION_LOCK_HELD=1` so the scripts it starts pass instead of waiting on it.

**Pre-restore copy.** The server folder as it was before a restore or rollback, kept as `<server>.pre-restore` by default (`RESTORE_KEEP_OLD`). `--discard-old` deletes it instead. Only one such copy exists; the next restore replaces it, and `cleanup_backups.sh` deletes it after `RESTORE_KEEP_OLD_DAYS` (default 7).

**Staging mirror.** The persistent copy of the server directory at `$BACKUPS_PATH/.stage/mirror` that `backup.sh` refreshes with `rsync --delete` while auto-save is off and then archives. Only changed files are copied on each run. The default staging mode (`BACKUP_STAGING_MODE=auto`) uses it unless the filesystem can clone files (`reflink`). It is never built from hardlinks: region files are rewritten in place.

**Save-off window.** The time between `save-off` and `save-on` during a backup, when the server runs without auto-save. Only staging happens inside it; compression and verification happen after. Every run logs its length and `last_backup.json` records it as `save_off_seconds`.

**Sidecar.** The checksum file `$BACKUPS_PATH/.meta/<tier>/<name>.sha256` written when an archive is published. Cleanup treats an archive with a sidecar newer than itself as valid without decompressing it; restore and rollback compare the recorded hash with the file before picking an archive by name. An older archive gets its sidecar from cleanup after a one-time `zstd -t`, and only when its mtime backs the stamp in its name.

**Due tier.** An archive tier (daily, weekly, monthly) that `run_backup.sh` still owes for the current day: its flag `.backup_flags/<tier>_<date>` does not exist and it has failed fewer than `BACKUP_ARCHIVE_MAX_ATTEMPTS` times today. All due tiers are made in one run from one archive. The pure function `bk_due_tiers` in `backup/lib/bk_schedule.sh` computes the list.

**Carry-over.** The entries a restore copies from the live server tree into the restored one because no backup contains them: `logs/`, `crash-reports/` and `ledger.sqlite` by default (`RESTORE_CARRY_OVER`). The archive's own copy wins when it has one.

**Partial archive.** An archive still being written, named `<tier>/.minecraft_backup_<stamp>.tar.zst.part`. The leading dot keeps it out of every `minecraft_backup_*` listing; it is renamed to its final name only after verification, and a stale one is removed by the next locked run.

**Instance lock.** A named per-instance lock (`maintenance`, `onjoin`) that keeps a second copy of the same script from running. Separate from the operation lock.

**Confirmed save.** A `save-all flush` the server has acknowledged: over RCON the command's reply, in screen mode the server's own "Saved the game" log line written after the command was sent. A backup of a running server is made only after one.

**Mkdir lock.** The lock used where `flock` is missing: a folder `<lock file>.d` holding a `pid` file, taken over when that process is gone. The shell scripts and the Node mod scripts both use it, so they still exclude each other.

**Forced chunk.** A chunk kept loaded with `/forceload`, stored per dimension in `data/chunks.dat`. The prune never deletes one.

**Prune backup.** The archive named to `prune-chunks.js --apply` with `--backup=<archive>`. The script checks that the file exists, has content, lies in the backups folder and is recent; the upgrade job passes the archive it made.

**Route.** One of the three ways `main.sh` runs setup: Default (safe defaults, almost no questions), Guided (a whiptail wizard) or Power-user (your own `variables.json` and flags, no wizard). It is chosen from the situation or forced with `--default` or `--guided`.

**Step manifest.** The data table in `src/wizard/` that lists every wizard question: the `variables.json` key it fills, its text, widget, default, validators and the routes it appears in. Adding a setting means adding an entry, not a new screen.

**Correction.** A value setup changed on its own for safety, such as a smaller heap, a different port or a new instance name. Each one is shown as a block marked `ADJUSTED:` or `WARNING:` and listed again on the summary and final screens.

**Safe heap.** The Java memory size the wizard picks from the memory available (the lower of `MemAvailable` and the cgroup limit): it reserves the larger of 1 GB or 25% of it for the system and gives the server the rest, capped at 8 GB, with a floor of 1 GB.

**Prerequisite stage.** The first part of `main.sh`, before any question or any use of Node: it installs only the missing system tools (and Node 18 or newer by the policy in the README), plus `whiptail` on the Guided route.

**Export snapshot.** In the optional creative mirror (`docs/mirror.md`), an immutable, flushed copy of the mirrored dimensions' `region/`, `entities/` and `poi/` folders that the survival server publishes under `<target>/mirror/<instance>/export/snapshots/<stamp>/`, with a `MANIFEST`. The creative server pulls it read-only and never reads the live world. Not the same as the backup staging mirror, although `MIRROR_SOURCE_MODE=stage` builds it from that mirror.

**Pull cache.** The creative server's persistent copy of the last pulled export snapshot (`<target>/mirror/<instance>/sync/cache/`), kept so each night transfers only the changed region files. It sits outside the server folder, so creative backups do not include it.

**Mirrored dimension.** One of `dimensions/minecraft/{overworld,the_nether,the_end}` (by default only the overworld) whose chunk folders the nightly pull replaces on the creative server. The plot dimension (`dimensions/fabricplots/plots`), `level.dat`, `data/`, `players/` and the dimension's own `data/` folder are never copied.

**Mirror role.** What a server is in the optional creative mirror: `source` (the survival server that publishes snapshots, through the read-only `mcsync` account) or `target` (the creative server that pulls them). Set by `mirror.sh setup source|target` or the `MIRROR` block of `variables.json`; a server without a role is not part of any mirror.
