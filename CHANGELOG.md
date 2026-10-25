# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Changed

- **Breaking: setup now installs a vanilla/Fabric server by default; `--modpack` selects a CurseForge modpack.** The `--vanilla` flag is removed (an unknown flag now stops with an error) and `npm run setup:vanilla` is replaced by `npm run setup:modpack`. Anyone who ran plain `main.sh` for a modpack must now pass `--modpack`. `main.sh --check` only reports the CurseForge settings when `--modpack` is given.

- **The hourly backup and the scheduled restart now run from systemd timers instead of the crontab.** Setup writes `<instance>-backup.timer` and `<instance>-restart.timer` (oneshot services run as the server owner; no sandboxing options, because the jobs use `sudo` and screen). `migrate.sh` moves an existing install over (new server migration `cron_to_timers`): the timers are enabled and verified first, then only the suite's own cron lines are removed, with the old crontab kept and any unusual schedule or missing `sudo` reported as a manual step. Hosts without a running systemd keep cron lines. `manage.sh doctor` checks the timers (next run, last result) and warns when a job has both a timer and a cron line.

### Fixed

- **Backups work again in the default (screen) mode on Minecraft 26.3.** 26.3 logs `System chat: Saved the game`, which the confirmed-save wait never matched, so every backup aborted after 120 s. The pattern is now anchored to the whole log line (timestamp and thread included, so chat cannot fake it) and accepts the 26.3 console and RCON forms. The same prefix change had hidden the player list in screen mode, so player-aware restarts could not read the count; fixed the same way (`common/server_control.sh`).
- **The backup staging mirror stays private after a refresh.** `rsync -a` copied the group-write bit of a world created under `umask 002` (the Debian and Ubuntu default) back onto the mirror; the refresh now strips group and other write (`backup/lib/bk_stage.sh`). CI runs the backup suites under `umask 002` as well.
- `--api-server` on a config without an API key no longer deploys a wrapper that crash-loops: setup generates a key, stores it in `variables.json` and never prints it. Setup and `doctor` warn when the host Node is older than the wrapper's `engines.node`.
- `update-mods.js`, `update-server.js` and the other update scripts answer `--help` and `-h` with their usage and exit; `update-server.js` used to start a real update. `main.sh --check` finds `cron` and `setfacl` in `/usr/sbin` for a normal user. `doctor` warns instead of failing about a backups folder that the first backup has not created yet.
- Tests no longer depend on the weekday (the daily/weekly tier tests failed on Sundays), the `systemctl` shim answers `list-unit-files` like systemd 257, and the migrate check for the retired web interface no longer treats every host as having its unit.

### Security

- **A failed setup run no longer deletes the whole install.** The rollback removed the entire base directory, so a failure while adding a second instance (or any re-run) took every instance, world and default backup with it. Setup now records what exists before its first change and rolls back only the paths and units it created, puts the crontab back exactly and restores the shared wrapper's config. `TARGET_DIR_NAME` must be a plain folder name (`src/common/setup.sh`, `src/setup/common/loadVariables.js`).
- **The wrapper's service user can no longer get code run as the server owner.** It loses write access to `plugins/`; restore and rollback refuse archives not owned by the user running them; without a terminal restore needs `--file` and `--y` and leaves the archived scripts alone unless `--with-scripts` (`service_user.sh`, `backup/restore.sh`, `rollback.sh`, `common/archive_restore.sh`).
- **The generated sudoers file installs, and allows exactly the wrapper's calls.** Alias names are upper case (visudo rejected the file, which aborted setup) and each script is listed with the arguments the wrapper passes (restore `--file <backups>/… --y`, backup `--archive`, the mod and prune scripts with their flags). `docs/sudoers-setup.md` drops its wildcard rules, which matched any script and any unit, for the same exact rules.
- **Console text is escaped for screen.** `^M`, `\015` and `$VAR` in a message typed into the console through screen ran a second command; `_screen_send` escapes them and drops control characters. `message_onjoin.sh` escapes its JSON and reads only a message file owned by its user; joins are recognised from the server's own line only (`common/server_control.sh`, `message_onjoin.sh`, `common/utils.sh`).
- The example's API key placeholder is refused. Setup-time mod downloads and the vanilla jar are verified like on the upgrade path; the Fabric installer is verified against the checksum its maven publishes before it runs; the Jabba installer is fetched by commit.
- `variables.json` and `curseforge_variables.json` are no longer tracked by git (they were, despite `.gitignore`); setup creates `variables.json` from `variables.example.json` on the first run. **Copy your `variables.json` aside before pulling this change**, git removes the tracked copy. The migration archive is created with `umask 077`.
- CI runs the shell and node tests; the ShellCheck action is pinned by commit; workflows use read-only tokens and pass `bot_ref` through the environment.
- **Granting the wrapper's user access no longer follows symlinks.** `service_user.sh` runs as root on folders the server user (and its mods) owns. It now refuses a target that is a symlink or sits behind one, requires each resolved path to stay inside its instance folder, uses `setfacl -P`, and grants on `world/stats` only when `level-name` is one plain folder name. A refused path is reported and the script exits 1.
- `restore.sh` refuses `--with-scripts` and `--install-units` without a terminal, so the wrapper's sudoers rule can no longer put archived scripts or units back. `docs/sudoers-setup.md` and `docs/service-user.md` now say what the wrapper's key is worth: installing a Modrinth mod, running an upgrade and typing console commands.
- The `.mc-meta` folder (a copy of `variables.txt` with the RCON password, webhook URL and API key) no longer survives in the live server folder after `rollback.sh` or a failed `restore.sh`, and `backup.sh` never includes one.
- `check_updates.sh` passes the CurseForge key to curl on stdin instead of the command line.
- **Chunk deletion needs a backup you name, and the script checks it.** `prune-chunks.js --apply` takes `--backup=<archive>` (or `MC_PRUNE_BACKUP`): a non-empty `.tar.zst`/`.tar.gz` inside the backups folder, at most a day old. The `--backed-up` flag and `MC_PRUNE_BACKED_UP` no longer count as proof. The upgrade job passes the archive it just made.
- Downloads are bounded and verified: setup's CurseForge server pack has a start timeout, a transfer deadline, a size cap, https-only redirects and a SHA-1 check against CurseForge's, and every download goes through a temporary file created exclusively. Plain-http download URLs are refused.
- A server pack zip is listed before it is unpacked and refused if an entry is an absolute path, has a `..` segment or is a symbolic link.
- JDK names from Jabba's remote index are checked (letters, digits and `. _ @ + -`) and passed to `bash` as an argument instead of being spliced into a command (`update-server.js`, `install_java.js`). `docs/upgrade.md` notes that the JDK archives themselves are not checksum-verified, because Jabba's index publishes no digests.
- `add-mod.js` registers a same-named file already in `mods/` only when it matches the checksum Modrinth publishes, and otherwise replaces it with a verified download. `toggle-mod.js` refuses a manifest file name that is not a plain name.
- A chunk that inflates past 64 MiB, or an external `.mcc` file over that size, is treated as unreadable and left alone (a decompression bomb can no longer exhaust memory during a scan).

### Added

- **One-command setup with three routes.** `bash main.sh` now works straight after `git clone`: the Default route uses safe defaults and almost no questions, the Guided route is a whiptail wizard with Back and Cancel and a plain-language explanation per step, and the Power-user route keeps the existing `variables.json` and flags. Both new routes end by writing `variables.json`. The README opens with a quick start, the three routes and a notice about reaching the server from outside the home network.
- **A prerequisite stage** installs only the tools that are missing before anything asks a question, and checks the Node version: an installed Node 18 or newer is used, otherwise the distribution's package when it is 18 or newer, otherwise Node 22 from NodeSource, which needs `--allow-nodesource`.
- **Safe defaults with loud corrections.** Memory is derived from the available RAM, the server port is 25565 or the next free one, and an instance name already in use gets a free one. Each change is shown as an `ADJUSTED:` or `WARNING:` block and repeated on the summary and final screens, which also print the port and the machine's local address.
- **The Default route picks a Minecraft version that works with the default mods.** It looks back at most three releases and, if some mods have no build, leaves those out. New optional keys: `JAVA.SERVER.PORT` (default 25565, written to `server-port`) and `JAVA.SERVER.VANILLA.MODS.EXCLUDE` (mod slugs left out of the install).
- **Xaero's Minimap and World Map stay optional on the client.** Setup writes three config lines under `config/xaero/` so players without the mods can join, re-applies them after mod updates, and `manage.sh doctor` reports a missing or changed line. `misc/xaero_config.sh apply <server_dir>` re-applies them by hand.
- New options `--default`, `--guided` and `--allow-nodesource`.

- Setup now installs `jq`, so webhook notifications work without a manual install, and `--check` also verifies `jq`, `unzip`, `cron` and `setfacl`.
- **`manage.sh doctor [instance]`** checks an installed instance without changing anything: the unit is enabled and running with crash-loop limits, the backup (and restart) cron jobs exist, backup usage and free disk space are within bounds, the wrapper's sudoers file parses, and the wrapper answers and accepts the configured API key. `--test-webhook` also sends one test notification and reports whether the endpoint accepted it. Run it as an admin with sudo.
- **The `storage_warning` and `server_stop` webhook events now fire.** `storage_warning` is sent when backups are still over `MAX_STORAGE_GB` after cleanup has evicted everything it may; `server_stop` when `shutdown.sh` (and so `manage.sh stop` or the wrapper's stop action) has stopped the server. The README lists every event and when it is sent.
- Setup warns about names in `NOTIFICATIONS.WEBHOOK_EVENTS` that no script sends.

- **A dedicated user for the API wrapper.** `API_SERVER.SERVICE_USER` (or `src/setup/management/service_user.sh` by hand) creates an unprivileged system user for the wrapper, grants it with ACLs read on the instance, scripts, backups and wrapper folders and write only on the config folders, `server.properties`, the config snapshot folder, `world/stats` and the backup folders, and writes a validated sudoers file that names the exact scripts, `systemctl` actions and `screen` commands it may run. Adds `UMask=0002` to the instance's unit. See `docs/service-user.md`.

- `update/upgrade.sh <version>` and `upgrade-server.js`: the whole version upgrade as one job (plan check, countdown, stop, archive backup, install, start and watch). If the first start fails the mods without a build for the target are disabled and it starts again; if that fails too, this job's own backup is restored. Progress is NDJSON. See `docs/upgrade.md`.
- `update-server.js --plan`, `--apply`, `--json`, `--yes`, `--keep-incompatible`.
- `start.sh` writes lifecycle events (`jvm_start`, `jvm_exit`, `restart_scheduled`, `crash_loop_gave_up`) to `logs/lifecycle.ndjson` and sends a `server_crash_loop` webhook when it gives up. Restart behaviour is unchanged.
- `acquire_operation_lock` in `common/utils.sh`: one slot per instance for restore, rollback, backup and upgrade; a refused run exits `75`.
- `common/instance_ops.sh`: announce, stop, halt, start, running and notify as small commands.

- `world/prune-chunks.js`: delete generated chunks nobody has used (InhabitedTime below a threshold) so a new Minecraft version regenerates them. Spawn, player positions, drawn zones and a buffer are never touched; region, entities and poi are pruned together; `--scan` is read only, `--apply` re-scans and deletes only what both scans agree on. `upgrade.sh --prune-plan=<id>` runs it inside an upgrade; `--prune-only` runs it alone, both under one backup. See `docs/chunk-pruning.md`.

- **Server-side migrations in `migrate.sh`** (`src/migrations/server.sh`, `docs/migrations.md`). Until now `migrate.sh` only updated the helper scripts and shared services; the files the suite wrote for the server itself never reached existing installs. `instance_start_script` updates `<instance>/start.sh` (old copy kept, takes effect at the next start) and `unit_start_limits` adds crash-loop limits to the instance's systemd unit (daemon-reload, no restart). Detected from the real files, previewed, idempotent, recorded in `common/server-migrations.log`, never restarts the server. New options `--list-server-migrations` and `--no-server-migrations`.

### Changed

- On the Power-user route the prerequisites are now installed before any prompt.
- `server-port` is now always written to `server.properties`, from `JAVA.SERVER.PORT` or 25565.
- Setup no longer needs `npm install` first; it installs Node and its packages itself.
- A failed or rolled-back install keeps `variables.json` and says so.
- **One setup script.** `main-vanilla.sh` is gone: run `main.sh --vanilla` for a vanilla/Fabric server (`npm run setup:vanilla` does the same). `npm run check:vanilla` is removed because `--check` is the same for both.
- With `API_SERVER.ENABLED` set to true, setup deploys the API wrapper without asking; it still asks when it is false, and `--api-server` still works.
- The documented Bash minimum is now 4.3 (the argument parser already needed it).
- `migrate.sh` is split into modules under `migrate-lib/` (the server-side migrations moved there from `src/migrations/`). It still lives in the repo root and behaves the same: same options, output, files and recovery. `docs/migrations.md` describes the layout.

- **The API wrapper is installed from its release, not a submodule.** `api-server-release.json` pins a wrapper version and its sha256; `--api-server` downloads that built release from GitHub, checks it and runs `npm ci --omit=dev` (`src/setup/management/install_api_server.js`). A host without the wrapper downloads nothing, and cloning no longer needs `--recurse-submodules`. `migrate.sh` replaces an installed wrapper that is not the pinned release (including a copy from the submodule days), keeping `api-server-config.json` and `logs/`; a failed download leaves the running wrapper untouched. The wrapper's `dist/` is now always present: the old copy step never built it. A leftover `src/scripts/api-server/` in a checkout is no longer used and can be deleted. See `docs/wrapper-release.md`.
- **Terrain tiles.** `prune-chunks.js --tile --dimension --rx --rz` draws a region from above as a PNG for the dashboard's terrain view, cached under `common/prune/tiles/` by the region file's fingerprint and trimmed to 500 MB. `tests/bench/render-tile.cjs` renders one for a real world.
- **Build protection** for `prune-chunks.js`: with `buildProtection: "likely"` (the default; `"off"` ignores it) a chunk the rules would delete is kept as uncertain when it holds block entities (chests, signs, furnaces, beds, redstone parts, anything modded) that no generated structure or spawner explains. `--inspect` reports everything about one chunk of a plan. The record cache holds the signals and is rebuilt once after this update.
- `prune-chunks.js` accepts a manual selection (`selection` in the parameters: add/remove rectangles in chunk coordinates, at most 2,500). Chunks chosen by hand are deleted even where a soft rule (in use, buffer) keeps them; with `allowProtected` they also override spawn, player areas and drawn zones; unreadable chunks are never deleted. The summary counts them per dimension (`manualSoft`, `manualHard`, `manualBlocked`) and the map marks them (cell classes 6 and 7). Parameters can be read from stdin (`--params-stdin`). The selection is never saved as a default.
- `prune-chunks.js --scan` reads regions on worker threads into a per-region record cache and prints NDJSON progress. A repeat scan takes about a tenth of the time, changing a threshold, radius, buffer or zone reads no region file, and `--apply` reads only the regions it deletes from (in parallel). Options `--workers` and `--no-cache`.
- `update-server.js` records the new version after the jar swap instead of before it, and disables incompatible mods (reversible, `mods/disabled/`) instead of deleting jars by filename match.
- `backup.sh`, `restore.sh` and `rollback.sh` take the operation lock, so they no longer overlap with each other or with an upgrade.
- The shell test runner now fails a test that stops before its last statement (an `exit`, or an `errexit` leaked from a sourced script, used to end it silently with assertions unrun) and a test that makes no assertion at all; `tests/shell/test_assert_harness.sh` tests the runner itself. New tests cover the prune protections, spoofed chunk tags, decompression bombs, unknown spawn, mod update error statuses, `$` in `server.properties` values, setup download failures, and the interactive update's Java ordering.

### Fixed

- Setup no longer calls `node` before it is installed, and a missing or too old Node now gives a clear message instead of a hidden error.
- The README no longer contradicts itself on the API port default (3000 when `API_SERVER.PORT` is left out), and its configuration example is valid JSON.
- Version-update webhooks (`update_complete`, `update_failed`) were not sent when `NOTIFICATIONS.WEBHOOK_EVENTS` was empty, although an empty list means every event.

- **A migration no longer stops the Minecraft server just to replace its scripts.** The running server has none of them open (backups, updates and the prune run as their own processes, and `start.sh` is only read at start), so it is now stopped only to move its instance folder to the new layout, or with the new `--restart`. Instead the migration takes the operation lock, so it never swaps the scripts under a running upgrade, prune, restore or mod change; when one holds the lock it stops before changing anything. A changed `start.sh` is pointed out as applying at the next start (`migrate.sh`).
- **`minecraft-server-manager/` is no longer reported on every migration.** Git leaves a removed submodule's folder in the checkout as untracked files, so `src/scripts/minecraft-server-manager/` was copied into the instance each time and reported for removal the next. Like `api-server/`, it is now left out of the copy, and the checkout's leftover is named with the command to delete it (`migrate.sh`).
- **Terrain of chunks saved by Minecraft 26.3 is drawn.** 26.3 writes a section's block palette as plain ids when no block in it has properties, and otherwise as `{id, properties}` entries with the plain ones wrapped as `{"": id}`; the tile reader only knew `{Name, Properties}`, so every section 26.3 had saved looked like air and the chunks players had been in since the update stayed empty. All three forms are read now, and tiles drawn before are drawn again (`world/lib/nbt.js`, `world/lib/tiles.js`).
- **A migration keeps the suite's own state.** `.locks/` (operation locks), `common/migration-backups/` (units the server migrations replaced), `common/server-migrations.log` and `common/upgrade-status.ndjson` (the last upgrade or prune job) were deleted on every migration and listed as stale files, which also made every run look like it had changes. They are kept now, folders with their permissions (`migrate.sh`).
- **Prune protects spawn, player areas and zones on Minecraft 26.x worlds.** 26.x keeps the overworld, the Nether and the End under `dimensions/minecraft/` and player files under `players/data/`. The engine found the dimensions there as `minecraft:overworld` and so on, which spawn protection and zones saved for `overworld` did not match, and it read no player positions at all; only the time and buffer rules kept chunks. The vanilla dimensions now keep their ids in both layouts (the 26.x folders win over leftovers of the old ones), and player positions are read from `players/data/` and `playerdata/` (`world/lib/world.js`).
- **Terrain of very tall worlds is drawn where the ground is low too.** A world over 2048 blocks tall stores 12 bit height maps, which have as many longs as 11 bit ones; the width was guessed from unused bits, which are also zero where every column is low (around sea level), so those chunks were read as 11 bit and left empty. The width now follows from the world's height, which each chunk shows through its sections. Tiles drawn before are drawn again on the next look (`world/lib/tiles.js`).
- **A migration keeps your prune settings and protected zones.** It rebuilds the scripts folder and only carried a few files across, so `common/prune/settings.json` (the saved defaults, zones included) and `prune-apply.journal` (the warning about a delete that did not finish) were deleted every time. Both are kept now. Plans, the scan cache and the terrain tiles are still cleared, and reported in one `CLEAR common/prune/` line instead of one `REMOVE` line per file; those files alone no longer count as a reason to migrate (`migrate.sh`).
- Upgrade and prune jobs report the player warning and the stop as done once they are, so progress views no longer leave them running (`update/upgrade-server.js`).
- **Prune map terrain is drawn whole in very tall worlds.** A world more than 2048 blocks tall (a mod or datapack raising the height) stores its height maps with 12 bits per column, which takes as many longs as 11 bits; the tile reader took 11, so most columns read a wrong surface height and stayed empty, and the terrain showed as diagonal stripes. The entry width is now read from the data, and tiles drawn by the old reader are drawn again the next time they are looked at (`world/lib/tiles.js`).
- **Backups restore to a server that starts.** Archive backups replaced `server.jar` (and other jars) with links into `backups/jars/` that dangle once restored, and hourly restores dropped every jar. Archives now keep their real jars; a restore repairs links in older archives and, for an hourly archive, keeps the current server's jars. Jar pruning counts every archive folder (`backup/backup.sh`, `common/archive_restore.sh`, `backup/automation/cleanup_backups.sh`).
- Upgrades across a Java major version no longer always roll back: the upgrade points the server's `JAVA=` at the JDK it installed (`update/update-server.js`). JDKs are picked by version, not string order.
- Removing a mod no longer deletes other mods whose names start with its slug (`sodium` took `sodium-extra`); a legacy entry that matches several jars is refused (`update/remove-mod.js`).
- Mod changes are serialized with each other and with restore, rollback and upgrade, manifest writes are atomic with per-process temp files, and a corrupt manifest is an error instead of an empty one (`update/lib/opLock.js`, `update/lib/manifest.js`).
- Mods that fail to update during an upgrade are reported (`keptOnOldBuild`) instead of a silent success; `upgrade-server` passes the version after `--` and `update-server --apply` needs an exact version; `add-mod` on a registered mod installs dependencies an earlier run missed.
- Backups use `save-all flush` and wait for the server's own "Saved the game" line; auto-save is turned back on even when `save-off`'s reply was lost; a scheduled restart no longer stops a server mid-backup (stop and restart scripts take the operation lock); `shutdown.sh`/`restart.sh` continue when a save is not confirmed.
- `rcon.js` fails when the server hangs up before answering (it exited 0 with no output), reads full 4096-byte replies and fails fast on a broken stream.
- Retention runs after every backup, failed ones and archive runs included, so a full disk recovers; a count cap of `0` means no limit instead of deleting every hourly backup.
- Network calls and child processes in the update scripts have timeouts, so a stalled download cannot keep the server down with the lock held.
- Crash-loop protection works: `StartLimitIntervalSec`/`StartLimitBurst` are written to `[Unit]`, where systemd reads them; the `unit_start_limits` server migration moves them there on existing units.
- A failed `migrate.sh` puts the previous scripts back from its archive and starts the server again if it stopped it; new scripts are built aside and swapped in.
- `prune-chunks.js --apply` needs a backup behind it (the upgrade job, or `--backed-up` by hand), and a region is pruned only when its region, entities and poi files are all safe to rewrite.
- Setup installs dependencies with `npm ci` from the committed lockfile and installs `acl`; `apt upgrade` runs only with `MC_SETUP_UPGRADE_SYSTEM=true`. New wrapper units get `KillMode=process` and a state directory so upgrade jobs survive a wrapper restart.
- `status.sh` counts a server reachable only by RCON as running; `manage.sh` matches whole session names; the non-bash readers of `variables.txt` handle escaped quotes and backslashes; `JAVA_ARGS` is escaped; the mkdir-fallback lock can no longer be taken over before its pid is written; an interrupted restore swap puts the original back.

- **An upgrade no longer stops with `mods_changed` when a mod the dashboard could not check turns out fine.** `upgrade-server.js --expect-unavailable` required the confirmed list to match its own check exactly, so a mod listed as unchecked (a timeout, a rate limit, or a slug like `sit!` the wrapper used to reject) failed the upgrade before it started. It now refuses only when its check finds a mod with no build that was not on the list, and names it (`unexpected`). On a crash loop it still disables only the mods its own check found unavailable (`docs/upgrade.md`).
- **Archive backups and restores lost the API wrapper config.** `backup.sh` and `restore.sh` took the server folder's parent as the install root, which in the `instances/` layout is `<root>/instances`. Archive backups therefore never carried `api-server-config.json`, `restore.sh` wrote it to `<root>/instances/api-server/` where the wrapper never reads it, and both named the wrapper's unit `instances-api-server.service`. The root now comes from the scripts folder, and the config is read from and restored to `services/api-server/` (`api-server/` on an older layout). After a restore with `API_SERVER.SERVICE_USER`, run `service_user.sh` again so the wrapper can read it.
- The shell tests for the backup, operation and instance locks passed only on hosts without `flock`: with a real one the busy-lock shim was never installed, and the held-lock helper slept through the sleep shim. The shim is now always installed and hands over to the real `flock` unless a test asks for a busy lock.
- A world with regions very far apart no longer fails a prune scan with a buffer; the buffer is computed per region.
- `prune-chunks.js --apply`: a chunk that was already corrupt no longer makes the post-prune check fail and roll the whole job back; the check now compares kept chunks byte for byte instead of re-reading them.
- `prune-chunks.js --apply` refuses to run when `instance_ops.sh` is missing (it used to assume the server was stopped), takes the operation lock when run by hand, rejects a plan whose content does not match its hash, and deletes only in folders found by the fresh scan.
- Region files with a chunk entry of zero sectors or overlapping sectors are left untouched by a prune instead of being rewritten.
- A negative array length in chunk data is rejected instead of looping.
- `prune-chunks.js --scan --params={}` uses the saved settings, as the dashboard expects.
- `prune-chunks.js --scan --profile` and `tests/bench/bench-prune.cjs` report where scan time goes.
- `check_updates.sh` reports a failed CurseForge request as "could not check" and exits 1, where it used to say an update was available.
- Setup removes its rollback copies of the crontab and the wrapper's config from `/tmp` when it succeeds, and the preflight no longer claims an empty API key leaves the wrapper unauthenticated (it refuses to start).
- **A backup now waits for a confirmed save.** `backup.sh` aborts with exit 1 and a `backup_failed` webhook when auto-save cannot be turned off or the `save-all flush` is not confirmed, instead of copying region files mid-flush. Over RCON the flush gets `SAVE_TIMEOUT_SECONDS` (default 120) rather than 5 seconds, a timeout counts as a failure and the command is no longer typed into the console a second time. A stopped server is still backed up as it is.
- Auto-save is switched back on as soon as the rsync snapshot is complete, no longer after compression and validation.
- `restore.sh --keep-old` and `rollback.sh --keep-old` keep the replaced server files as `<server>.pre-restore` (an older copy is replaced) so a wrong archive can be undone. Without the flag nothing changes.
- Backup cleanup now covers `archives/general` and custom archive types (`MAX_CUSTOM_BACKUPS`, default no count limit, plus storage eviction), orders archives by the timestamp in their file name instead of modification time, leaves `tmp_backup/` and `jars/` out of the size it measures, never deletes the newest valid archive of a tier, and skips while a restore, rollback or upgrade holds the operation lock.
- The operation and instance locks live in one folder per instance (`scripts/<instance>/.locks`, or `INSTANCE_LOCK_DIR`), so cron, an SSH session and the wrapper exclude each other. `$XDG_RUNTIME_DIR` no longer picks a different folder.
- Scheduled and smart restarts no longer treat an unreadable player count as zero: the screen-mode `/list` answer is read from the log position recorded before the command and matched only as the server's own line, and an unknown count is handled as "players are online". `get_player_count` and `get_player_list` fail when the server could not be asked.
- `maintenance.sh` no longer overwrites the saved MOTD when an earlier run did not finish, and skipped backups and restarts say so in the log.
- `rcon.js` accepts `--timeout-ms=N`.
- `migrate.sh` keeps its operation locks across the swap of the scripts folder (`.locks/` is moved into the new tree, not copied), puts the old layout back (instance folder, unit paths, `SERVER_PATH`, wrapper folder) when a step after the move fails, checks that the server really stopped before it moves the instance folder, matches instance names exactly (instance `mc` no longer matches `mc2`), prints the command that restores the wrapper user's ACLs after the swap, and keeps only the newest 5 `<scripts>_backup_*` archives (`MIGRATE_KEEP_ARCHIVES`).
- The API wrapper install is swapped in by renaming a finished folder, so a failure part way can no longer leave a half-deleted wrapper. The new folder keeps the old one's owner, mode and ACL, and `api-server-config.json`, `.env`, `variables.txt` and `logs/` carry over.
- The instance's systemd unit gets `TimeoutStopSec=300`, an `ExecStop` that flushes the world first, `PrivateTmp=true`, `ProtectSystem=full` and `ReadWritePaths`. Existing units are not rewritten.
- The backup and restart cron jobs stop when `crontab -l` fails for any reason other than "no crontab" instead of replacing the crontab with one that lost the other jobs, quote their paths, and the restart interval must divide 24 (or be whole days).
- The API wrapper's unit starts it with the node binary setup ran under.
- `start_server.sh` reports a server that did not start: through the unit it returns the start script's status, and under `--no-service` it launches the instance's own `start.sh` in screen and checks the session is still there.
- `loadVariables.js` requires whole numbers for `COMPRESSION_LEVEL`, `MAX_STORAGE_GB`, the `MAX_*_BACKUPS` counts and `INTERVAL_HOURS`.
- `$&`, `$$` and similar in the MOTD or RCON password are written to `server.properties` as typed (they were read as replacement patterns, which broke RCON authentication), and a trailing backslash or leading space in a value can no longer change the next line or be dropped.
- **Chunk pruning protects more.** Chunks kept loaded with `/forceload` (read per dimension from `data/chunks.dat`) and player respawn points (old and 1.21.5 layouts) are never deleted. Dimension ids now match between player files and the folder scan (`minecraft:custom` and `custom` are the same dimension). Unreadable player files and an unreadable `chunks.dat` are reported as plan warnings. `--apply` refuses a plan made without a readable `level.dat` (`spawn_unknown`) unless `--allow-unknown-spawn` is given.
- A fractional buffer, radius or threshold is rounded to a whole number, so a buffer of 1.5 no longer silently protects nothing. A manual selection across the whole coordinate range is applied in time proportional to the number of region files.
- The quick scan of a chunk no longer takes an `InhabitedTime` (or block entity, structure or status tag) from item data inside a block entity; it only accepts tags at the top of the chunk and otherwise falls back to a full walk.
- An unfinished prune apply is no longer erased or overwritten by a refused attempt: the earlier note is kept inside the new one and put back as it was if the new apply is refused before it deletes anything. `--tile` and `--inspect` reject a missing `--rx`, `--rz`, `--cx` or `--cz` instead of reading it as 0, and `--apply` answers in JSON when bash is missing.
- **Mod updates report what happened.** A mod that could not be checked, or has no build for the target version, is listed as failed (and a single `update-mod.js` exits 1) instead of "no update available". New required dependencies of an updated mod are installed. The new jar is renamed into place before the old one is deleted. Builds are chosen release first, then beta, then alpha (updates, `add-mod.js` and setup); an installed beta newer than the last release is not "updated" away. Slugs are URL-encoded.
- `remove-mod.js` keeps a mod's manifest entry when its jar cannot be deleted.
- Setup mod downloads exit non-zero when a mod or a required dependency is missing, has no published checksum or fails verification; the CurseForge server pack records no loader or version rather than the word "none" when it lists none.
- The mod scripts take the operation lock even where `flock` is missing, using the same `mkdir` lock as the shell scripts, and refuse to run when no lock can be taken (they used to run unlocked).
- An interactive `update-server.js` points the server at the new JDK only after the update is confirmed and the backup is done; an aborted update leaves `JAVA=` as it was.

### Removed

- The retired `--interface` flag and the setup warnings about a leftover `WEB_INTERFACE` block; the block is now ignored silently. The README no longer lists macOS as supported, since the suite needs systemd and cron.

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

- **One setup script.** `main-vanilla.sh` is gone: run `main.sh --vanilla` for a vanilla/Fabric server (`npm run setup:vanilla` does the same). `npm run check:vanilla` is removed because `--check` is the same for both.
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

