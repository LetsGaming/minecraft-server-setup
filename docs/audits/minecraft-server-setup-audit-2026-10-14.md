# minecraft-server-setup: project audit

- **Date:** 2026-10-14
- **Commit:** `cfb71cf` (v5.0.0, default branch)
- **Type:** audit only. No project files were changed.
- **Companion reports:** `minecraft-bot` and `minecraft-server-api` audits of the same date.

## 1. Executive summary

Several parts of this suite are careful work:

- **Region-file pruning:** temp file + fsync + rename, refuses overlapping sectors, re-hashes kept chunks, server-down check, journal.
- **Download verification on the upgrade path:** vanilla jar sha1, mod sha512/sha1, size caps, deadlines, safe filenames.
- **Wrapper install:** the tarball is sha256-pinned and staged.
- **Restore path handling:** `--file` cannot escape `BACKUPS_PATH`.
- **Secrets:** escaped correctly into `variables.txt` and written 0600.

The serious problems are elsewhere: in recovery paths that are rarely exercised for real, and in a privilege grant that is broader than the docs say.

**Top risks**

1. **A failed setup run deletes the entire install, including existing instances, worlds and backups** (S-001). The rollback trap runs `rm -rf` on the whole base directory, so a failure while adding a second instance or re-running setup wipes everything. Failure is currently *guaranteed* whenever `API_SERVER.SERVICE_USER` is set (S-005).
2. **Restoring a backup produces a server that cannot start.**
   - Archive restores, which include the upgrade auto-rollback and `rollback.sh`, replace `server.jar` with a dangling symlink (S-002, reproduced).
   - Hourly restores, the default, drop every `*.jar`, including mods and libraries (S-003).

   In practice the backup system cannot be used for recovery.
3. **The wrapper's service user can obtain code execution as the server owner**, normally the sudo-capable admin (S-004). It has write access to the backups folders and to `plugins/`, and may run `restore.sh`, which swaps in the whole server directory, scripts included.
4. **The generated sudoers file never installs** (S-005). Alias names contain lowercase letters, which `visudo` rejects. Even after that is fixed, the script entries allow only argument-less calls, so most wrapper calls (restore with `--file`, mod scripts, prune) would be denied.

**Structural weakness:** CI runs ShellCheck and a wrapper contract check but **never runs the test suite**. The test suite would have caught S-005: its sudoers test fails here.

**Finding counts:** Critical 1 · High 4 · Medium 14 · Low 12 · Informational 4.

## 2. Audit scope and method

- **Scope:** the whole repository, weighted by risk.
  - Setup and rollback, `migrate.sh`, the service user, sudoers and ACLs, systemd units, cron.
  - Backup, restore, rollback and cleanup; server control (RCON and screen), the operation lock, save handling.
  - Upgrade, mod and prune scripts; downloads and integrity checks; Java installation.
  - Docs that prescribe privileges; CI; tests.
- **Context assumed** (carried over from the earlier interview):
  - These scripts are run by an admin, and remotely by the mc-api-server wrapper through `sudo -u <server user>`.
  - Inputs from the wrapper are only loosely validated; for example, arguments may start with `-`.
- **Method:** static review first.
  - Three parallel read-only reviews: backup/restore/control; update/mods/prune/downloads; install/migrate/privileges/CI.
  - I re-checked every Critical and High finding and most Medium ones in the source.
  - S-002 was reproduced with the repo's own test fixtures and shims.
  - S-016's systemd behaviour was checked with `systemd-analyze verify` on a throwaway unit.
  - Findings not independently re-checked are marked "traced".

## 3. Findings

### [CRITICAL] S-001: A failed setup run deletes the whole install root, including other instances, worlds and backups

**Location**
- `src/common/setup.sh:174-222` (`run_rollback`: `sudo rm -rf "$base_dir"`, stops/disables the shared `<target>-api-server`, removes every cron line containing the base dir)
- `main.sh:46-54` and `main-vanilla.sh:46-53` (EXIT/INT trap)
- `src/setup/variables/set_common_variables.js:26-29` (default `BACKUPS_PATH` = `<base>/backups/<instance>`)

**Evidence**
- The rollback does not record what this run created. It removes `$MAIN_DIR/$TARGET_DIR_NAME` wholesale.
- The layout is multi-instance, and re-running setup to add an instance is a documented flow (`create_api_server_service.js:9`: "On subsequent runs (adding a new MC instance)…").
- Any failure in such a run destroys every existing instance's server directory, world, scripts and default backups. Examples:
  - a network or CurseForge error
  - a jabba installer hash change (S-027)
  - missing `setfacl` (exit 3)
  - Ctrl-C during `apt upgrade`
  - the sudoers rejection in S-005, which currently fails every run that sets `SERVICE_USER` with a lowercase instance name
- `TARGET_DIR_NAME` is checked only for being non-empty. A value of `.` gives `base_dir=$HOME/.`, which passes the string guard, so the rollback runs `rm -rf ~`.

**Remediation**
- Track the paths, units and cron lines this run actually creates, and roll back only those.
- Never remove a directory that existed before the run.
- Validate `TARGET_DIR_NAME` with the same pattern as `INSTANCE_NAME`.
- Until fixed, warn loudly at the start of a re-run.

**Confidence:** verified by code reading (rollback body, trap, `set -e`, default backups path). Not executed against a real install.

### [HIGH] S-002: Archive backups replace `server.jar` with a dangling symlink, so archive restore, upgrade rollback and `rollback.sh` all yield an unbootable server

**Location**
- `src/scripts/backup/backup.sh:203-213`: for every `*.jar` found anywhere under the server, `ln -sf "../../../jars/$jarname" "$TMP_DIR/$jarname"`.
- `src/scripts/backup/automation/cleanup_backups.sh:~110-111`.

**Evidence**
- In archive mode rsync copies the real jars into staging. The loop then overwrites the top-level `server.jar` (and `fabric-server-launch.jar`) with a relative symlink, and adds stray root-level links for every jar in `mods/`, `libraries/` and so on.
- The link only resolves from inside the backups tree. After a restore swaps the directory into `SERVER_PATH`, it points nowhere.
- Reproduced with the repo's fixtures: `backup.sh --archive` followed by `restore.sh --archive --y --file …` leaves `server.jar -> ../../../jars/server.jar`, which cannot be read.
- This is the archive the upgrade job restores on failure, and the one `rollback.sh` uses.
- Aggravating factors:
  - `jars/` is keyed by base name only, so a new `server.jar` after an upgrade is never stored.
  - The cleanup scan only considers daily, weekly, update and monthly archives, so jars referenced only by `general` or custom archives are deleted after a day.

**Remediation**
- Store real jars in the archive, or place links at each jar's real relative path and dereference them from `jars/` during restore.
- Key `jars/` by content hash.
- Add an end-to-end backup → restore → "jar is a regular file" test.

**Confidence:** verified (reproduced).

### [HIGH] S-003: Restoring an hourly backup (the default) removes every jar, including mods and libraries

**Location**
- `src/scripts/backup/backup.sh:178-181`: `--exclude=*.jar` in hourly mode, which matches at any depth.
- `src/scripts/common/archive_restore.sh:~84-100`: `swap_server_dir` replaces the whole `SERVER_PATH`.

**Evidence**
- Hourly archives contain no `server.jar`, no `mods/*.jar` and no `libraries/**/*.jar`.
- Restore swaps the archive in as the complete server directory and nothing carries jars over, so the server cannot start.
- The test suite's rsync shim ignores excludes, so the tests cannot see this.

**Remediation:** before the swap, copy `*.jar` (or `mods/` and `libraries/`) from the current server directory into staging when the archive has no jars. Alternatively, exclude only top-level jars and have restore re-link them.

**Confidence:** verified by code reading. Not executed with real rsync.

### [HIGH] S-004: The wrapper's service user can gain code execution as the server owner

**Location**
- `src/setup/management/service_user.sh:~37` (read-write list includes `plugins/`), `:~178-183` (rwx ACL on backups folders), `:100` (`restore.sh` grant).
- `src/scripts/backup/restore.sh:~142-187` (newest archive picked by mtime; stdin confirmation; `.mc-meta/scripts` rsynced over the scripts dir).
- `src/setup/management/create_service.sh:28` (`ExecStart` runs the instance's `start.sh`).

**Evidence**
- The service user can:
  1. stop the unit (granted);
  2. write a crafted archive into `hourly/`;
  3. run `echo y | sudo -u <owner> bash …/restore.sh`, which by default picks the newest archive;
  4. start the unit again.
- The restored directory, including `start.sh` and optionally the whitelisted scripts themselves, then runs as the owner.
- Simpler on Paper/Bukkit: drop a jar into `plugins/` and restart.
- `check_root` and `require_sudo` make the owner the sudo-capable admin, so on typical NOPASSWD images this ends at root.
- This defeats the boundary stated in `docs/service-user.md`, that scripts must stay unwritable by the service user.

**Precondition:** the wrapper process is compromised, for example by remote code execution or a leaked API key combined with a route that reaches restore.

**Remediation**
- Do not give the service user write access to any folder that restore or the server loads code from. Route deletion through an owner-run script instead.
- Make restore refuse archives not owned by the owner.
- Require explicit `--file` and `--y` under sudo, with no stdin prompt.
- Skip `.mc-meta/scripts` when not interactive.
- Remove `plugins/` from the read-write list.

**Confidence:** strongly supported (traced; the chain was not executed).

### [HIGH] S-005: The generated sudoers rules never install, and would deny most wrapper calls if they did

**Location:** `src/setup/management/service_user.sh:76-117` (`su_sudoers_content`), `:212-219` (`visudo -cf`, then abort); `tests/shell/test_service_user.sh`.

**Evidence**
- **Alias names:** `local id="${inst//[^A-Za-z0-9]/_}"` keeps lowercase letters, but sudoers alias names must be uppercase. `visudo` 1.9.15 rejects `Cmnd_Alias MCS_testinst_UNIT` ("syntax error"), so `su_die` exits and nothing is installed. The repo's own `test_the_generated_rules_parse` fails here for this reason. With S-001, the abort also triggers the full-install rollback.
- **Arguments:** entries such as `bash $sd/backup/restore.sh` carry an argument list (the script path), so sudo requires an exact match. These calls are all denied:
  - `restore.sh --file <archive> --y`, which the wrapper documents
  - `backup.sh` with flags
  - `prune-chunks.js …`
  - every `*-mod.js … --json -- <slug>`

  `test_service_user.sh` asserts that there is no `/*`, which locks this in.

**Remediation**
- Upper-case the alias id (`${id^^}`).
- Add explicit, tight argument patterns per script, for example `restore.sh --file <backups>/* --y`, but only after S-004 is fixed.
- Run the test suite in CI (S-017).

**Confidence:** verified (the test fails with real `visudo`; sudoers argument semantics are documented).

### [MEDIUM] S-006: `docs/sudoers-setup.md` recommends rules that grant arbitrary code execution and any-service control

**Location:** `docs/sudoers-setup.md`.

**Evidence**
- `/usr/bin/bash /home/minecraft/*/scripts/*` puts the wildcard in an *argument*, where `*` matches `/`. So `bash /home/minecraft/x/scripts/../../../tmp/evil.sh` matches. The doc's claim that "sudo wildcards do not match '/'" is only true for command paths.
- `systemctl stop minecraft-server-*.service` also matches `… minecraft-server-a.service sshd.service`, so it can stop or restart any unit as root.

**Remediation:** list exact scripts with explicit argument patterns and drop the wildcard service rules. Correct the explanation.

**Confidence:** verified for the doc text and standard sudo semantics.

### [MEDIUM] S-007: Upgrades that need a newer Java major version always roll back

**Location**
- `src/scripts/update/update-server.js:~293-386`: installs and locates the JDK, but never updates the instance's `JAVA=`.
- `src/vanilla/download/install_java.js:62-87`: the only writer of `JAVA=`, used at setup time.
- `src/vanilla/start.sh:50-61`: launches `${JAVA}`.

**Evidence:** for example 1.20.4 (Java 17) to 1.20.5+ (Java 21). The new jar fails with `UnsupportedClassVersionError`, the start watch times out, and the job restores the backup, which is itself affected by S-002. Upgrades across Java majors therefore cannot succeed.

**Remediation:** after `ensureJavaVersion` in `--apply`, atomically rewrite `JAVA=` in the deployed `variables.txt`, and restore it on rollback.

**Confidence:** verified by code reading.

### [MEDIUM] S-008: Removing a mod also deletes other mods whose names share its prefix

**Location:** `src/scripts/update/remove-mod.js:~97-106` (always adds the slug-scan matches, even when a recorded filename exists); `src/scripts/update/lib/jars.js:22-27` (regex `(^|[-_.])<slug>([-.+_]|$).*\.jar`).

**Evidence**
- Removing `sodium` deletes `sodium-extra-fabric-*.jar`; removing `carpet` deletes `carpet-extra-*.jar`.
- The victim's manifest entry remains, so `add-mod` reports it as already registered, `update-mod` reports it as up to date, and toggling it fails with jar-missing. It cannot be recovered without editing the manifest by hand.

**Remediation:** when a recorded filename exists, delete only that file. Use the slug scan only for legacy entries, and refuse when it matches more than one jar.

**Confidence:** verified (code and regex).

### [MEDIUM] S-009: Backups are taken after `save-all` without `flush`

**Location:** `src/scripts/common/server_control.sh:~297` (`/save-all`), `:~264-268` (RCON wait is `sleep 2`), `:~282` (completion pattern `'Saved the (game|world)|Saved'`); `backup.sh:~197`.

**Evidence**
- On 1.17+, `save-all` without `flush` queues chunk writes to the I/O thread. "Saved the game" is logged before the region files are on disk, so rsync can copy torn `.mca` files from a busy server.
- The pattern also matches any later log line containing "Saved", including player chat.

**Remediation:** send `save-all flush`, and anchor the pattern to `\]: Saved the (game|world)`.

**Confidence:** strongly supported (based on Minecraft's save semantics; not run against a live server).

### [MEDIUM] S-010: `rcon.js` exits 0 when the server closes the connection without replying

**Location:** `src/scripts/common/rcon.js:~112-114`.

**Evidence**
- The `close` handler clears the timeout but never settles the promise, so Node exits 0 with no output.
- `save-off`, `save-all` and `save-on` can be silently lost, because the screen fallback never runs. A server that is shutting down reads as "up".
- The reviewer reproduced this with a TCP server that closes immediately.

**Remediation:** reject on `close` if the promise has not settled.

**Confidence:** strongly supported (traced and reproduced by the reviewer).

### [MEDIUM] S-011: Auto-save can stay disabled after a backup

**Location:** `src/scripts/backup/backup.sh:~152` (`disable_auto_save && _AUTO_SAVE_DISABLED=true || …`).

**Evidence:** if the server executes `save-off` but RCON times out and no screen session exists for the fallback, the flag stays false. Neither the normal path nor the exit trap then sends `save-on`, and the world stops auto-saving until the next restart.

**Remediation:** set the flag *before* sending `save-off`, so `save-on` is always attempted.

**Confidence:** strongly supported (traced).

### [MEDIUM] S-012: `shutdown.sh` and `restart.sh` abort when the save isn't confirmed

**Location:** `shutdown.sh:~25` and `restart.sh:~24` (bare `save_and_wait` under `set -e`).

**Evidence:** a save that isn't seen within 60 s, or a screen session that isn't detected, exits the script before `systemctl stop`/`restart`. Players have already been warned at that point. `instance_ops.sh` and `smart_restart.sh` handle this correctly with `|| warn`.

**Remediation:** use `save_and_wait || echo "[WARN] …"`.

**Confidence:** strongly supported (traced).

### [MEDIUM] S-013: A failed backup skips cleanup, so a full disk never recovers on its own

**Location:** `src/scripts/backup/automation/run_backup.sh:~79-105`.

**Evidence**
- Under `set -e`, a failed backup exits before `cleanup_backups.sh` runs.
- Daily, weekly and monthly runs `exit 0` before cleanup as well.
- Once the disk is full, every hourly backup fails and retention is never enforced again.

**Remediation:** always run cleanup (`run_backup_script … || rc=$?; cleanup; exit $rc`), and consider running it before the backup too.

**Confidence:** strongly supported (traced).

### [MEDIUM] S-014: Mod download failures during an upgrade are reported as success

**Location:** `src/scripts/update/update-mods.js:~222-226, 266-267` (per-mod failures collected, exit 0); `src/scripts/update/update-server.js:~412-421, 509-510`.

**Evidence:** a mod that failed to update (network error, hash mismatch) stays on its old-MC build while the job reports `{ok:true}`. The server then either runs with a stale mod or rolls back without saying why.

**Remediation:** exit non-zero or emit `failed[]`, and surface it in the apply result.

**Confidence:** strongly supported (traced).

### [MEDIUM] S-015: Network calls and child processes have no timeout while the server is stopped and the lock is held

**Location**
- axios calls without `timeout`: `update-server.js:~112,133,348,363,373`, `check-updates.js:~66,72`, `add-mod.js:~126,143,165`.
- `fetch` without abort: `install_api_server.js:~90`.
- `spawnSync` without timeout: `upgrade-server.js:~361`.

**Evidence:** a half-open connection during `--apply` blocks forever. The server stays down and every other operation gets exit 75 (locked).

**Remediation:** set a default axios timeout, use `AbortSignal.timeout` for fetch, and add timeouts to child runs.

**Confidence:** strongly supported (traced).

### [MEDIUM] S-016: Crash-loop protection never takes effect

**Location:** `src/setup/management/create_service.sh:40-42` (`StartLimitIntervalSec=`/`StartLimitBurst=` in `[Service]`); `src/migrations/server.sh:~125`.

**Evidence**
- systemd 255 reports "Unknown key name 'StartLimitIntervalSec' in section 'Service', ignoring". The interval stays at the 10 s default, and with `RestartSec=3s` the limit can never trip, so a broken server restarts forever.
- The migration's `grep '^StartLimit'` check treats these broken units as already migrated.

**Remediation:** move the keys to `[Unit]`, or use the compatible `StartLimitInterval=`, and make the migration check the effective setting.

**Confidence:** verified (unit text read; `systemd-analyze verify` on a throwaway unit).

### [MEDIUM] S-017: CI never runs the test suite, and one action is unpinned

**Location:** `.github/workflows/shellcheck.yml` (`ludeeus/action-shellcheck@master`); `.github/workflows/wrapper-contract.yml` (`${{ inputs.bot_ref }}` interpolated into `run:`, reachable only by users with dispatch rights).

**Evidence:** neither `tests/shell/run.sh` nor `node --test tests/js` runs in CI. That is how S-005 shipped while its own test fails.

**Remediation:** add a test job, pin the action to a SHA, and pass inputs via `env:`.

**Confidence:** verified.

### [MEDIUM] S-018: The example API key passes validation

**Location:** `variables.example.json` (placeholder `replace-with-a-long-random-secret`, 33 characters); `src/setup/common/loadVariables.js:~63`, `src/common/setup.sh:~413` (length ≥ 32 is the only check).

**Evidence:** an operator who enables the API server and forgets to set the key runs the wrapper with a publicly known key.

**Remediation:** reject the placeholder, or generate a key when it is unset or still the placeholder.

**Confidence:** verified.

### [MEDIUM] S-019: `migrate.sh` can leave the server down without its scripts after a partial failure

**Location:** `migrate.sh:2` (`set -euo pipefail`, no trap); the server is stopped at about line 717; wipe-then-copy at about lines 944-946.

**Evidence**
- If anything fails after the stop, for example `cp` because the disk is full, the server stays down and the scripts directory is empty or partial.
- The only copy of the deployed `variables.txt`, which holds the secrets, is left in a `mktemp` directory.
- Recovery instructions are printed only when verification fails, not when the script aborts.

**Remediation:** add an ERR/EXIT trap that restores the pre-migration archive and restarts the server if this run stopped it. Copy into staging and swap, rather than delete-then-copy.

**Confidence:** strongly supported (traced).

### [LOW] S-020: Setup-time mod downloads use the API filename as a path and verify no hash

**Location:** `src/setup/download/download_mods.js:~140-144`; `download_utils.js:~28-38`.

**Evidence**
- `path.join(downloadDir, file.filename)` is used without sanitising and with no sha512 check, and stream errors are not handled, so a truncated download can count as complete.
- The filename is recorded in the manifest, which later remove and update operations unlink.
- The upgrade path (`lib/download.js`) already does all of this correctly.

**Remediation:** reuse `safeFilenameFromUrl` and `downloadVerified`.

**Confidence:** strongly supported.

### [LOW] S-021: The Fabric installer jar is executed without verification

**Location:** `update-server.js:~361-378`; `download_server.js:~81-85, 106-111, 187-196`.

**Evidence**
- The Fabric installer is downloaded and run with `java -jar` without a checksum.
- Setup-time vanilla jars skip verification when no sha1 is present.
- JDKs installed by jabba are not verified.

**Remediation:** verify against published hashes where available, and fail closed.

**Confidence:** strongly supported.

### [LOW] S-022: `mcVersion` is forwarded without `--`, and can select "latest"

**Location:** `src/scripts/update/upgrade-server.js:~162, 238`.

**Evidence:** a version string such as `--version=--yes` is parsed as a flag by `update-server.js`, which then upgrades to the latest release rather than the requested one. No flag skips the backup.

**Remediation:** insert `--` and validate the version (`^[0-9A-Za-z][0-9A-Za-z._+-]*$`). This mirrors finding W-013 in the wrapper report.

**Confidence:** strongly supported.

### [LOW] S-023: A failed dependency install during `add-mod` is never retried

**Location:** `src/scripts/update/add-mod.js:~219-226, 362-419`.

**Evidence:** the main mod is registered before its dependencies are installed. Re-adding it returns "already registered" before reaching the dependency loop, so a required dependency stays missing.

**Remediation:** check dependencies even when the main mod is already registered, or register the main mod only after all dependencies succeed.

**Confidence:** strongly supported.

### [LOW] S-024: Mod operations have no lock, and manifest writes are non-atomic and share temp names

**Location**
- add, remove, toggle and update-mod take no operation lock.
- Non-atomic writes: `update-mods.js:~215-219`, `update-server.js:~86-90`.
- Shared `downloaded_versions.json.tmp`: `add-mod.js:~99`, `remove-mod.js:~123`, `download_utils.js:~109`.
- `update-server.js:~78-84` reads a corrupt manifest as `{}`.

**Evidence:** a dashboard mod change during an upgrade's apply or rollback can lose updates or garble the manifest. A corrupt manifest becomes `{}`, and the next save writes only `gameVersion`, dropping every mod entry.

**Remediation:** per-process temp names, a manifest lock (or the operation lock), and fail on a parse error.

**Confidence:** strongly supported.

### [LOW] S-025: Plain `prune --apply` takes no backup, and damaged entity/POI files are skipped while terrain is pruned

**Location:** `src/scripts/world/prune-chunks.js:~23, 339-374`; `lib/plan.js:~767-780`.

**Evidence**
- Only the upgrade job's `--prune-only` path backs up first.
- When an entities or POI file is unsafe it is skipped while the region file is still pruned, so old entities reappear in regenerated chunks.

**Remediation:** expose apply only through `upgrade.sh --prune-only`, and check all three folders before touching any of them.

**Confidence:** strongly supported.

### [LOW] S-026: Console injection via `message_onjoin.sh` arguments on the screen path

**Location:** `src/scripts/misc/message_onjoin.sh:~88-93`.

**Evidence**
- `--title` and `--message` are placed unescaped into a JSON command typed into screen, where a newline or `^M` starts a new console command.
- `--messageFile` reads any file the server user can read.

**Remediation:** reject control characters and `^`, and build the JSON with `jq`. This is related to W-001 in the wrapper report.

**Confidence:** strongly supported. Only exploitable if something forwards untrusted arguments to this script.

### [LOW] S-027: Supply-chain and reproducibility gaps

**Location:** the repo root, `src/setup/download_packages.sh` (`npm install --no-package-lock`, `apt upgrade -y`), and `install_jabba.sh:~20-21`.

**Evidence**
- `package-lock.json` is absent, even though `.gitignore` states it is committed. `npm ci` fails, and installs float on `axios ^1` and `semver ^7`.
- Setup runs `apt upgrade -y` on every run and never installs `acl`, which `service_user.sh` requires.
- The jabba installer's sha256 is pinned against a mutable `main` branch URL. Any upstream commit breaks vanilla setup, which then triggers S-001.

**Remediation:**
- Commit a lockfile and use `npm ci --omit=dev`.
- Install `acl`.
- Make the system upgrade opt-in.
- Pin jabba to a tag or commit URL.

**Confidence:** verified.

### [LOW] S-028: `variables.json` and `curseforge_variables.json` are tracked despite `.gitignore`, and the README says to edit them in place

**Location:** the repo root; `docs/secrets-management.md:~3` (claims `variables.json` is git-ignored).

**Evidence**
- Once a file is tracked, `.gitignore` has no effect. Local edits holding the RCON password, API key and webhook URL show up as modifications, and `git commit -a` or `git stash`/`git push` habits can publish them.
- Both files currently contain only empty or placeholder values.

**Remediation:** `git rm --cached` both files, keep only the `*.example.json` templates, and have setup copy the example on first run.

**Confidence:** verified (`git ls-files`; placeholder values checked by key and length only).

### [LOW] S-029: Migration backup archive holding secrets is created with the default umask

**Location:** `migrate.sh:~692-698`.

**Evidence:** the archive includes `common/variables.txt`, which is deployed with mode 0600, but the archive itself is written 0644. It is readable by other local users wherever `$HOME` is world-traversable.

**Remediation:** `umask 077` around the tar, as `backup.sh` already does.

**Confidence:** strongly supported.

### [LOW] S-030: Lock and miscellaneous robustness issues

**Evidence**
- The mkdir-fallback operation lock has a takeover race between `mkdir` and writing the pid file, so two processes can both hold it (`utils.sh:~54-63, 101-111`). This only applies without `flock`.
- `restore.sh:~166` replaces the EXIT trap without releasing the lock.
- `smart_restart.sh`, `shutdown.sh`, `restart.sh` and `maintenance.sh` take no operation lock, so a scheduled restart can stop the server mid-backup.
- `backup.sh:~328`: `[[ … && ! $DRY_RUN ]]` is always false, so success webhooks report an empty size.
- `MAX_HOURLY_BACKUPS=0` deletes every hourly backup.
- `manage.sh:~108` uses a substring `grep` for the instance name.
- `misc/status.sh` reports "Not Running" for servers reachable only by RCON.
- Non-bash parsers of `variables.txt` (`create_api_server_service.js:~85`, `service_user.sh:72`) mishandle values containing `"` or `\`.
- `JAVA_ARGS` is written unescaped into the sourced `variables.txt`; this is operator-controlled input.
- JDK selection uses a plain string sort, so `21.0.9` sorts after `21.0.10`.

**Confidence:** strongly supported (traced).

### [LOW] S-031: Interrupt windows during the restore swap

**Location:** `archive_restore.sh:~90-92`; the same pattern in `rollback.sh`.

**Evidence:** a signal arriving between the two `mv` calls lets the trap delete staging. The original data then survives only as `<server>.pre-restore.<pid>`, which the user may not know to look for.

**Remediation:** have the trap restore the pre-restore directory when the swap is incomplete.

**Confidence:** strongly supported.

### Informational

- **Test failure explained:** `test_save_and_wait_catches_a_save_that_finishes_instantly` fails only when run as uid 0. `_screen_send` goes through `sudo -u`, which the test's sudo shim blocks. This is not a product bug. Fix it by passing `screen` through the shim.
- **Docs mismatches:**
  - `docs/secrets-management.md` says to use environment variables, but setup still writes secrets to files.
  - `docs/reverse-proxy.md` assumes port 3000 while the example uses 3030, and does not say to bind the wrapper to loopback or firewall it.
- **Answers to the wrapper audit's open questions:**
  - `--prune-only` passed as `mcVersion` cannot skip the backup.
  - A `..` dimension cannot escape the world directory: ids must equal discovered dimensions, and paths are `isInside`-checked.
  - The wrapper release tarball and the jabba installer are sha256-verified.
- **What is solid:**
  - Region rewrite safety and NBT bounds checks.
  - Upgrade-path download verification.
  - `--file` restore containment, and GNU tar's default member-path protections.
  - Backup pipeline exit-code handling (`pipefail`, `PIPESTATUS`, `zstd -t`, `tar -t`).
  - Secret escaping in `variables.txt`, with 0600 modes; `api-server-config.json` is 0600 with a single read ACL.
  - No `curl | bash`.
  - Idempotent cron entries.
  - `migrate.sh`'s `rm -rf` uses `:?` guards.

## 4. Coverage and limitations

- **Inspected adequately:**
  - setup and rollback, the service user, sudoers and ACLs, systemd unit generation
  - backup, restore, rollback and cleanup; server control and save handling; the operation lock
  - upgrade, mod and prune scripts; download integrity; Java install
  - CI workflows
- **Inspected with limits:**
  - `migrate.sh` lines 200-520 and 1150-1226
  - `maintenance.sh`
  - `load_chunks.sh`
  - CurseForge modpack unpacking (`unzip -o` on an unverified pack)
  - `pool.js`, `scan.js`, `cache.js`; `tiles.js` PNG encoding
- **Not inspected:** behaviour on a real host (systemd, sudo, ACLs, live Minecraft).
- **Checks run (actual outcomes):**

  | Check | Result |
  |---|---|
  | `npm ci` | failed: no lockfile (S-027) |
  | `npm install --no-package-lock` in a throwaway clone | succeeded |
  | Shell and JS suite (`tests/shell/run.sh`) | Shell: 2 suites failed. `test_server_control` fails because of the uid-0 sandbox (Informational). `test_service_user` fails because of the real `visudo` rejection (S-005). JS: 176 of 177 passed before dependencies were installed; the single failure was the missing `axios`, and it passes once dependencies are present. |
  | Fixture reproduction of S-002 | reproduced |
  | `systemd-analyze verify` on a throwaway unit for S-016 | key ignored |
  | `npm audit` | not possible without a lockfile |

- **Not run:** setup, migrate or any real sudo/systemctl/visudo against the system; live backup, restore or upgrade.
- **Assumptions that could change conclusions:**
  - S-001's severity assumes re-running setup on an existing install is a supported flow, as the code comments state.
  - S-004 assumes the service user and the owner are distinct and the owner has sudo, as `check_root` and `require_sudo` imply.

## 5. Conclusion

**Priorities**

1. **Stop the setup rollback from deleting pre-existing data** (S-001), and fix the sudoers generation (S-005) that currently triggers it.
2. **Make backups restorable:** jar handling in archive and hourly modes (S-002, S-003), plus an end-to-end restore test.
3. **Narrow the service user's write access** so it cannot plant code that the owner later runs (S-004), and correct the sudoers documentation (S-006).
4. **Run the existing test suite in CI** (S-017).

**Principal limitation:** nothing was exercised on a real host, so systemd, sudo and live-server behaviour is inferred from code, documentation and sandboxed fixtures.
