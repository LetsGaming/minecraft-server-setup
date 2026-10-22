# Backup/restore code audit (Agent 1, code deep-dive)

Scope: `src/scripts/backup/backup.sh`, `restore.sh`, `automation/run_backup.sh`, `automation/cleanup_backups.sh`, `automation/scheduled_restart.sh`, `src/scripts/common/archive_restore.sh`, `src/setup/management/create_backup_job.sh`, `migrate-lib/backup.sh`, plus the parts of `server_control.sh`, `utils.sh`, `webhook.sh`, `load_variables.sh` they depend on. Read-only review; the test suite was not run. Findings marked "(unverified)" were derived by reading and not reproduced.

Line references are to the current working tree. Paths are relative to the repo root.

## 0. Summary table

| ID | Sev | Area | One line |
|----|-----|------|----------|
| P1 | High | perf | `prune_orphan_jars` decompresses and lists every archive on every cleanup while a legacy `jars/` dir exists, even with zero jars in it |
| P2 | High | perf | Full copy of the server dir (rsync) happens inside the save-off window; no incremental/reflink staging |
| B1 | High | restore | Default restore irrecoverably deletes the previous server tree; no automatic safety copy |
| B2 | Medium | restore | Restore deletes live data that backup excludes (ledger.sqlite, logs, `*.gz`) |
| B3 | Medium | restore | Restore run via sudo/root leaves the server root directory owned by root (unverified) |
| B4 | Medium | backup | Archive is written straight to its final name; readers can see a partial file |
| B5 | Medium | run_backup | A failed or skipped midnight daily is never retried (slot only matches hour 0) |
| B6 | Medium | security | TOCTOU between `archive_is_trusted` and extraction |
| B7 | Medium | backup | `set -e` aborts and rsync failure produce no webhook; several exits skip `wait_for_notifications` |
| B8 | Medium | backup | `nice_run` only tests that `ionice` exists, not that it works; a failing `ionice` fails the backup |
| B9 | Medium | backup | Cleanup trap deletes the multi-GB staging tree before it re-enables auto-save |
| B10 | Medium | backup | Symlinked world/data dirs are archived as symlinks (data not captured) (unverified in practice) |
| B11 | Medium | backup | No disk-space preflight; eviction runs only after the backup |
| B12 | Medium | ops | No watchdog/timeouts: a hung step keeps the lock, and a killed script leaves save-off |
| P3 | Medium | perf | Archive is decompressed 2x at backup validation, 3x in restore, plus cleanup `zstd -t`, none niced in cleanup |
| P4 | Medium | perf | zstd `-T0` uses all cores during the tick; ionice is a no-op on most modern block schedulers |
| P5 | Medium | perf | Weekly/monthly/daily each rebuild a full level-15 archive; Sunday runs back to back |
| P6 | Medium | restore | Server is down for validation (2 passes) plus extraction; staging could be built while up |
| B13 | Low | many | See section 3 (smaller defects) |

---

## 1. Performance bottlenecks

### P1 (High) Orphan-jar scan decompresses every archive every hour on legacy installs
`src/scripts/backup/automation/cleanup_backups.sh:200-231`

```bash
[[ -d "$jar_dir" ]] || return 0
...
listing=$(zstd -d "$archive" -c 2>/dev/null | tar -tvf - 2>/dev/null) \
...
done < <(find "$BACKUP_BASE/archives" -type f \( -name '*.tar.zst' -o -name '*.tar.gz' \) ...)
...
done < <(find "$jar_dir" -maxdepth 1 -type f -name '*.jar' -mmin +1440 ...)
```

The guard is only "does `jars/` exist". The scan of all archives (every tier, including monthly) runs before the code looks at whether any jar is old enough to delete. Since `backup.sh` no longer creates `jars/` (comment at backup.sh:232-237), once the old jars are pruned the empty directory stays forever and the scan keeps running. `run_backup.sh:101` runs cleanup after every backup, so this is hourly.

Scenario: an install upgraded from the symlink-jars era has 40 GB of archives. Every hour at :2x, cleanup decompresses all 40 GB (un-niced; `nice_run` only wraps `du` at line 257) and holds each full `tar -tvf` listing of a modded server (hundreds of thousands of lines) in a shell variable. This competes with the game server for CPU, disk and RAM.

Fix: (1) compute the candidate jar list first and return early if empty; (2) `rmdir "$jar_dir"` when it holds no jars, so the whole path disappears; (3) wrap `zstd`/`tar` in `nice_run`; (4) stream the listing into the `sed` instead of `listing=$(...)`.

### P2 (High) The whole-world copy happens while auto-save is off
`backup.sh:172-230`

```bash
disable_auto_save || abort_backup ...
save_and_wait || abort_backup ...
sleep 2
...
nice_run rsync -a --inplace --numeric-ids "${EXCLUDES[@]}" "${INCLUDE_PATHS[@]}" "$TMP_DIR"
...
enable_auto_save
```

Save-off lasts for the full duration of a from-scratch copy of the entire server directory (world, mods, libraries in archive mode). The server accumulates dirty chunks in memory for that period (memory pressure, long stall at the `save-on` catch-up), and a crash loses everything since the flush. `--inplace` is meaningless into a freshly emptied directory (TMP_DIR is `rm -rf`'d at line 211).

Fix options, best first:
1. Keep a persistent staging mirror (for example `$BACKUP_BASE/.stage`) and `rsync -a --delete` into it. Only changed region files are copied, so the save-off window drops from minutes to seconds on a large world. Make the archive from the mirror afterwards.
2. On XFS/btrfs use `cp -a --reflink=auto` (near instant). Never use hardlinks: region files are modified in place, so a hardlinked snapshot would change after `save-on`.
3. At minimum drop `--inplace` and the useless `sleep 2` (line 178; the flush is already confirmed).

### P3 (Medium) Repeated full decompression passes
- `backup.sh:327`: `zstd -t` followed by `zstd -d -c | tar -tf -`. The second pass already detects corruption (zstd checks the frame checksum; `pipefail` propagates), so `-t` is a duplicate full read.
- `archive_restore.sh:47-48` (`validate_archive`): same double pass, then `extract_archive` (line 69) is a third pass. Three decompressions before the first byte of the restored world exists.
- `cleanup_backups.sh:86` `archive_is_valid` runs `zstd -t` on the newest archive of a tier: once in `delete_surplus` (line 115) for hourly every hour, again per tier in `enforce_storage_limit` (line 267) whenever the limit is exceeded. Not niced.

Fix: single pass `zstd -d -c | tar -tf -` (pipefail) in both places. In cleanup, `protected_archive` can stop at "non-empty and filename matches" or cache a validity marker (for example a `.ok` sidecar written by backup.sh after validation), and be niced.

### P4 (Medium) CPU and I/O priority do not do what the comments promise
- `backup.sh:308`: `nice_run tar ... | nice_run zstd -T0 ...`. `-T0` spawns one worker per core. Nice 10 helps CPU scheduling but not memory bandwidth, and the Minecraft server's chunk/IO threads are many. On a 4 vCPU VPS the tick thread still loses cores for the whole compression, which is the symptom `create_backup_job.sh:24-28` describes ("CPU-saturating zstd -T0"). Level 15+ for archives (line 299) multiplies this: zstd level 15 on multi-GB data takes many minutes at 100% of every core.
- `ionice -c2 -n7` (line 48) is honoured only by BFQ (and the legacy CFQ). Debian/Ubuntu NVMe and virtio disks default to `none` or `mq-deadline`, where it is ignored (unverified for this host; check `/sys/block/*/queue/scheduler`).
- `nice_run` is applied to `du` in cleanup but not to `zstd -t`, `zstd -d`, `tar -tvf` (P1, P3).

Fix: expose `BACKUP_ZSTD_THREADS` (default `max(1, nproc/2)`), consider `--rsyncable`, use `ionice -c3` (idle) where BFQ exists, apply the cgroup route if systemd is present (`systemd-run --scope -p CPUWeight=20 -p IOWeight=10`), and use `nice_run` consistently.

### P5 (Medium) Full re-archiving for every tier; Sunday pile-up
`run_backup.sh:73-91`. Daily, weekly and monthly are each a complete tar+zstd at level >= 15 of the same data (`backup.sh:297-300`). On a first Sunday the runs go: 00:20 monthly, 01:20 weekly (the monthly flag now exists so the `elif` chain falls to weekly), and no daily at all that day (the `HOUR -eq 0` branch is last in the chain). Two heavy level-15 archives in consecutive hours, plus a missing daily on every Sunday.

Fix: build the archive once, then `ln`/`cp --reflink` it into the other tier directories that are due the same day. Keep one `date`-keyed decision function so a Sunday still gets a daily.

### P6 (Medium) Restore downtime includes validation and extraction
`restore.sh:175-203`. `require_server_stopped` (175) precedes `validate_archive` (178) and `extract_archive` (197). The staging directory is next to the server dir, not inside it, so validation and extraction could run while the server is still up (rollback.sh already validates before stopping per docs). Only the swap needs the server down. The wrapper already insists on `offline`, so this is mainly about the CLI path and about how long the "restore" window is when a human is waiting.

### Other perf notes
- `backup.sh:186-189` builds `INCLUDE_PATHS` by globbing and rsyncs them as separate arguments; fine, but names beginning with `-` would be parsed as options (see B13).
- Hourly archives exclude `*.jar` (line 203), which keeps them small. Good.
- `migrate-lib/backup.sh:17` archives the whole scripts dir including `node_modules` (no `--exclude`), single-threaded `zstd -3`. Low impact (one-off).
- `cleanup_backups.sh:63-72` calls `date -r` per file only for names without a timestamp; fine.

---

## 2. Bugs, races, cleanup gaps

### B1 (High) Restore deletes the current world by default, irrecoverably
`archive_restore.sh:191` (`rm -rf -- "$old"`), `restore.sh:203`.

After `mv staging server`, the previous tree is removed unless `--keep-old` was passed (`restore.sh:203`: `"$($KEEP_OLD && echo keep)"`). The wrapper path runs `--y --file <abs>`, so there is no prompt either. A mis-selected file (`--ago` picks the closest by mtime, in either direction, with no distance limit: `restore.sh:147-152`) permanently destroys the live world with no copy anywhere.

Failure scenario: an admin restores "2h ago" intending the pre-grief state; the closest archive by mtime is a re-copied older file; the live world is gone, hourly retention is 3 files by default (`MAX_HOURLY_BACKUPS`), so the true "before" state may be gone as well.

Fix: default to keeping the old tree (`<server>.pre-restore`, one generation) and make deletion opt-in (`--discard-old`), or take an automatic `--archive pre-restore` backup first. At minimum print the size and the fact that nothing will remain.

### B2 (Medium) Restore also wipes data that backup intentionally excludes
`backup.sh:192-199` excludes `logs/*`, `*.log`, `*.tmp`, `crash-reports/*`, `*.gz`, `ledger.sqlite`. `swap_server_dir` replaces the entire directory. After every restore the following are gone: all logs and crash reports (exactly what you need to diagnose why you restored), the Ledger database, and any `*.gz` data files. `complete_staged_jars` carries over only jars (`archive_restore.sh:103-134`).

Scenario: a corrupted world is restored; `ledger.sqlite` (rollback history for grief) vanishes and with it the means to investigate.

Fix: before the swap, move excluded-class files from the old tree into staging (or use `--keep-old` default per B1 and document it).

### B3 (Medium, unverified) Root-run restore leaves the server root owned by root
`archive_restore.sh:65-67,169`: the staging directory is created by whichever user runs restore (`mkdir -p`), and `swap_server_dir` copies only the mode (`chmod --reference`). `restore.sh:20-41` documents that the wrapper runs it through sudo. Contents extracted by root with GNU tar keep archived numeric owners, but the top-level `instances/<name>` directory itself is root-owned. The game user then cannot create new top-level entries (`logs/`, `crash-reports/`, `session.lock` lives deeper, but `eula.txt`, `whitelist.json`, `usercache.json`, `.paper-remapped` are root-level files the server writes).

Fix: `chown --reference="$server" -- "$staging"` next to the chmod (line 169), and in `extract_archive` pass `--no-same-owner` unless running as the owner.

### B4 (Medium) Partial archive is visible under its final name for the whole compression + validation
`backup.sh:295-305`: `zstd ... -o "$ARCHIVE_PATH"` writes directly to `minecraft_backup_<date>.tar.zst`. `PARTIAL_ARCHIVE` is only cleared at line 333. For minutes (compress, then two validation passes) other consumers see a growing file that matches `*.tar.*` and is the newest by mtime:
- the API wrapper's listing/download, any offsite sync (the code mentions PABS in run_backup.sh:30);
- `restore.sh` `find_latest_backup` (blocked by the operation lock, which is some protection, but only for scripts that use the lock);
- `cleanup_backups.sh` is also lock-protected.

Fix: write to `...tar.zst.part`, `mv` after validation succeeds (atomic on the same filesystem), and have consumers ignore `.part`. The `.part` also needs to be covered by the EXIT cleanup (it already would be via `PARTIAL_ARCHIVE`).

### B5 (Medium) Missed daily slot is never retried
`run_backup.sh:80`: `elif [ "$HOUR" -eq 0 ] && [ ! -f "$DAILY_FLAG" ]`. `docs/backup-restore.md:9` and the comment at line 50-52 say a skipped slot "is retried by the next run". True for weekly and monthly (any hour of the day), false for daily: the next run is at 01:20 where `HOUR=1`, so the daily is silently lost for that day. Same when the 00:20 archive fails (`rc != 0`, flag not touched, no retry). The failed run also does not fall back to an hourly backup, so there is a two-hour gap in coverage.

Fix: condition on "no daily flag for today" instead of hour 0 (optionally with `HOUR >= 0`); on archive failure fall back to an hourly run.

### B6 (Medium) TOCTOU between trust check and use
`restore.sh:169` (`archive_is_trusted`) ... `restore.sh:178` (`validate_archive`) ... `restore.sh:183` (interactive `read`, unbounded wait) ... `restore.sh:197` (`extract_archive`). The check is on the path; each later step re-opens the path. The S-004 threat model (the wrapper's service user can write into the backups directory to delete archives) lets that user delete the trusted archive and create a new file at the same path in the window. The new file is owned by the attacker but is never re-checked. The window includes the confirmation prompt on interactive runs and the full validation time on every run.

Fix: re-run `archive_is_trusted` immediately before extraction, better: `exec 3< "$file"`, check `stat -L /proc/self/fd/3`/`stat -c %u /dev/fd/3`, and feed `zstd -d <&3` so the checked inode is the used inode. Also check that the parent directory is not group/world-writable or that the file is mode 600.

### B7 (Medium) Failures that never reach the webhook or skip the flush
- rsync failure, `backup.sh:220-223`: logs and `exit 1`, no `send_message`, no `notify_error`. The only external signal is cron output. (The save, compress and validation failures all notify.)
- Any `set -e` abort (for example `mkdir -p "$BACKUP_DIR"` line 124, `cd "$SERVER_PATH"` line 184, the metadata `rsync` at line 256, `cp`/`du`) exits through the EXIT trap with no notification at all. The webhook only fires from hand-written paths.
- Lines 314-316 and 329-331 call `notify_error` (which backgrounds curl, webhook.sh:104-109) then `exit 1` without `wait_for_notifications`; only `abort_backup` (line 154) waits. The curl child usually survives the parent, but the docs claim "the script waits for in-flight notifications before it exits" (docs line 15).

Fix: one EXIT trap handler: if `$?` is not 0 or 75 and no notification was sent, `notify_error "backup_failed" ...; wait_for_notifications`. Remove the per-site duplicates.

### B8 (Medium) `nice_run` can turn a harmless priority call into a failed backup
`backup.sh:46-54` (same in `cleanup_backups.sh:16-24`). `command -v ionice` only proves the binary is installed. `ionice -c2 -n7 cmd` exits non-zero without running `cmd` when `ioprio_set` is refused (some LXC/gVisor/seccomp profiles, rootless containers). Then `rsync` "fails" (line 220), or the tar|zstd pipeline fails (line 312), and every backup aborts. The comment says the function "falls back ... rather than failing the backup", which it does not do for this case. (unverified on a real restricted container)

Also: `nice` missing but `ionice` present: `ionice ... nice ...` fails.

Fix: probe once: `ionice -c2 -n7 true 2>/dev/null` and `nice -n 10 true`, and pick the wrapper from the probe results.

### B9 (Medium) Trap frees disk before it turns saving back on
`backup.sh:17-31`. Order: `release_operation_lock`, `rm -f` partial archive, `rm -rf "$TMP_DIR"`, then `enable_auto_save`. In failure paths where save-off is still active (rsync failure at line 220, or a `set -e` abort between line 173 and 229), the world stays un-saved while `rm -rf` of a multi-GB staging tree runs (tens of seconds to minutes on HDD). The operation lock is also dropped before cleanup finishes, so a restore could start deleting/swapping while the trap is still running.

Fix: order the trap as: save-on first, then delete files, then release the lock last.

### B10 (Medium, unverified) Symlinks are archived as links
`backup.sh:220` uses `rsync -a`, which copies symlinks as symlinks. A common performance setup is `world -> /mnt/fast/world`, or a mods dir symlink. The archive then contains a dangling link and none of the data, and `zstd -t`/`tar -tf` validation passes. There is no check or warning.

Fix: detect top-level symlinks in `INCLUDE_PATHS` and either use `--copy-links` for them (`-K`/`--copy-dirlinks` on the argument), or warn and fail loudly.

### B11 (Medium) Disk-full handling is reactive only
- No `df` preflight anywhere in backup.sh. The staging copy needs about 1x the server size plus the archive on the same filesystem as the backups.
- `cleanup_backups.sh:252-262` compares `du` of the backups tree to `MAX_STORAGE_GB`. That is a quota on archive bytes, not a free-space check, and eviction runs after the backup. With `MAX_STORAGE_GB` close to the disk size, the next backup fails with ENOSPC first (rsync exit 11 or zstd write error; handled and cleaned up, good), and only then is space freed (S-013, `run_backup.sh:101`). This costs at least one lost backup per overflow.
- `du -sb` and `stat -c%s`, `find -printf`, `date -d`, `realpath -e` are GNU-only (fine on Linux, not portable to MSYS in all cases; tests shim `du`).

Fix: estimate required space (`du -sb` of the include set, minus excludes), compare with `df --output=avail`, run the eviction before the backup when short, and abort early with a clear notification.

### B12 (Medium) No watchdog; kill -9 or hang leaves save-off
- `create_backup_job.sh:30` runs `bash run_backup.sh >> ... 2>&1` with no `timeout`. A hung RCON read (node has a timeout), a stuck NFS rsync, or a zstd on a dying disk holds the operation lock and `.backup.lock` forever; every later run exits 75, logs a WARN and says "skipped". Hourly backups silently stop. No alert is sent on repeated skips.
- Only an EXIT trap exists (backup.sh:32). SIGKILL, OOM-kill or power loss between line 173 and 229 leaves auto-save off until the next successful backup (heals within an hour, since the next run ends with save-on). A kill of the process group while rsync runs: bash waits for the foreground child before running the trap for SIGTERM (unverified behaviour per bash version).
- If the server crashes while save-off is active, the archive is built from a pre-crash disk state and is reported as a clean success; nothing checks that the server stayed up and `session.lock` unchanged.

Fix: wrap with `timeout --signal=TERM --kill-after=60 <N>h`; send `/save-on` at the start of every run when the server is up (cheap self-healing); alert after N consecutive 75 skips; add `trap ... INT TERM HUP` that exits so the EXIT trap runs.

### Further correctness notes (Medium/Low)

**Restore may overwrite a server that started (Medium).** The two `require_server_stopped` checks (175, 202) bracket validation and extraction, but nothing blocks a start after the second check, and `start.sh` restarts a JVM that exits (docs line 23). The operation lock helps only if `start.sh` honours it; grep shows only `shutdown.sh`, `restart.sh`, `smart_restart.sh`, `maintenance.sh`, `upgrade.sh`, `rollback.sh`, `restore.sh`, `cleanup` and `backup.sh` take the lock. A systemd `Restart=` or manual `systemctl start` can race the swap. Fix: mask the unit or hold a start-blocking marker during the swap.

**Backup with the server "stopped" is not guarded against a start (Low/Medium).** `backup.sh:161-166` decides `SERVER_UP` once. If the server starts (crash-loop restart, admin) during the minutes-long rsync, the copy is torn but still validated and published. Fix: re-check `server_is_running` after the rsync; if it went from stopped to running, discard and retry.

**Live non-region files are copied while the server runs (Medium, unverified detail).** `save-off` freezes chunk writes, but plugin databases (SQLite/H2 for CoreProtect, dynmap, claims plugins), `playerdata` written on logout, and Ledger-like files are not frozen. `ledger.sqlite` is excluded but others are not. A torn SQLite file validates fine as tar. Fix: exclude or dump them with the DB's own backup API.

**Path traversal in archives (Low given the trust model).** `extract_archive` (`archive_restore.sh:69`) uses plain `tar -xf` into staging. GNU tar strips leading `/` and refuses `..` members by default, which blocks the simple cases. It does not prevent a symlink member followed by a regular member written through it, and it extracts as root when run via sudo with `--same-owner`. Only archives owned by the running user or root are accepted (`archive_is_trusted`), so exploitation needs B6 or a poisoned legitimate archive. `validate_archive` only checks that the archive lists; it does not inspect member names. Fix: after listing, reject members that are absolute, contain `..`, or are links whose target is absolute or escapes; use `--no-same-owner`, `--no-same-permissions` as appropriate.

**Hourly restore with no current jars (Low).** `complete_staged_jars` (`archive_restore.sh:105-115`) prints "keeping the current server's jars" even when `$server` has none (reinstall, or the first restore on a rebuilt box); the restored tree then has no server jar and nothing warns.

**Custom `BACKUPS_PATH` inside the server directory (Low, conditional).** The default is outside (`set_common_variables.js:28`), and `backup.sh:187` skips only a top-level entry literally named `backups`. A custom path inside the server dir under another name would be backed up into itself, and a restore would delete it with the old tree. No validation found in `loadVariables.js` (not exhaustively checked).

**Lock layering (Low).** `backup.sh` takes the operation lock (line 129) for the entire run and then `.backup.lock` (137). With `flock` present, the second lock only matters when `MC_OPERATION_LOCK_HELD=1` (upgrade) or for runs that bypass the first. It is correct but redundant, and the log message at line 139 can never be the one a second cron instance sees. On hosts without `flock`, `.backup.lock` is skipped but the mkdir fallback in `acquire_operation_lock` (utils.sh:113-127) still serializes backups, so docs line 9 ("runs unlocked") is too pessimistic.

---

## 3. Smaller defects (B13, Low)

| # | File:line | Evidence | Problem / fix |
|---|-----------|----------|---------------|
| a | backup.sh:73,106 | `--verbose) VERBOSE=true`; only used in `$VERBOSE && log INFO` | Flag is a no-op though `--help` says it makes rsync/tar/zstd verbose. Wire it up or remove it. |
| b | backup.sh:98,101 | `send_message "Starting hourly backup"` runs before the lock (129) | A skipped run (exit 75) and `--dry-run` still announce "Starting backup" to players. Move after lock acquisition and guard with `! $DRY_RUN`. |
| c | backup.sh:186-189 | `for item in * .*` | Empty dir leaves literal `*`; names starting with `-` become rsync options. Use `shopt -s nullglob dotglob` and `./$item`/`--`. |
| d | backup.sh:292,308 | `ZSTD_OPTS+=("-$COMPRESSION_LEVEL" ...)` | No numeric validation in bash (`load_variables.sh` only checks non-empty). Value `0`, `abc` or a stray `-` makes zstd read stdin or error. `loadVariables.js:57` validates only at setup time. Validate `^[0-9]+$` and clamp 1-19. |
| e | backup.sh:192-198 | `--exclude='*.gz'` etc. unanchored | Excludes any `*.gz` anywhere and `logs/*` at any depth (including plugin data). Anchor excludes (`/logs/`) and document. |
| f | backup.sh:343-346 | success log with empty path in dry run | Cosmetic: prints "Backup complete: " for dry-run. |
| g | backup.sh:35-39 | local `log()` overrides utils.sh `log` | Backup output is not written to the central log file (`log_file_path`); relies on cron redirection. `backup.log` grows unbounded (`create_backup_job.sh:30`, no logrotate). |
| h | restore.sh:143-152 | `find ... -printf | sort | head | cut` under `set -euo pipefail` | A missing tier dir makes `find` fail and the script dies before the friendly "No suitable backup found" message at line 168; a very large list can raise SIGPIPE in `sort`. Also `find -maxdepth 2` on `hourly/` can match a stale `hourly/tmp_backup/*.tar.*` data file from the server dir. Use `-maxdepth 1` for hourly, `-name 'minecraft_backup_*.tar.*'`, and `|| true`. |
| i | restore.sh:147-152 | closest-by-mtime | Cleanup orders by filename stamp (cleanup_backups.sh:59-79), restore by mtime. A copied/rsynced archive restores the wrong one. Parse the filename stamp in both. |
| j | restore.sh:193 | trap runs `rm -rf "${SERVER_PATH%/}/.mc-meta"` on every exit | Intended only for the success path; on a failed restore it deletes `.mc-meta` of the untouched live tree. |
| k | archive_restore.sh:191 | `rm -rf -- "$old"` on a multi-GB tree, with INT/TERM trap | An interrupt during the delete leaves `<server>.pre-restore.<pid>` orphaned forever (swap_recover only restores when the server dir is missing). Rename to a trash name and clean in the background, or document. |
| l | run_backup.sh:25 | `find "$STATE_DIR" -mtime +7 -delete` | Fine, but flags older than 7 days vs monthly flag logic is unaffected; no issue. (Noted as checked.) |
| m | run_backup.sh:94 | `_capture_update_snapshot` before `touch "$FLAG"` | `ln -sf` returns, then `|| true`; if it fails under `set -e` the `&&` chain is guarded. OK. But `latest-update-snapshot.tar.zst` symlink inside `archives/` is skipped by `find -type f` in restore; OK. Noted as checked. |
| n | scheduled_restart.sh:20-23 | exit 75 logged as WARN, no retry/notify | When a backup (up to many minutes at level 15) overlaps the restart time, the restart is silently skipped for that cycle. Add a bounded retry or webhook. |
| o | cleanup_backups.sh:247 | `[[ ... "$MAX_STORAGE_GB" -lt 1 ]]` | A decimal value (`1.5`) triggers an arithmetic error under `set -e` and aborts cleanup after the count caps. Validate as integer. |
| p | cleanup_backups.sh:130-135 | `exit 1` on invalid `MAX_*` | Aborts the whole cleanup, including later `enforce_storage_limit`, for a bad tier value. Prefer log + `return`. |
| q | migrate-lib/backup.sh:13-23 | no `tar -t`, no failure cleanup | A failed or interrupted `tar` leaves a truncated `*_backup_*.tar.zst`; the prune function (lines 30-45) would count it as one of the "newest few" and could delete a good older one. Create to `.part`, verify, rename. Also `ls -1 ... | sort -r` relies on the name format; fine. |
| r | create_backup_job.sh:30 | cron line has no `PATH` | Cron's default `PATH=/usr/bin:/bin`. `node` (used by `rcon.js`, server_control.sh:35), `zstd`, `rsync` installed under `/usr/local/bin` or via nvm are not found; `_rcon_send` fails, falls back to screen, and with `send_command_strict` the save is never confirmed and every backup aborts (unverified; depends on how node is installed). Add `PATH=` to the crontab or export it in run_backup.sh. |

---

## 4. Error handling, logging and recovery evaluation

What is solid:
- Save handling: `_AUTO_SAVE_DISABLED` is set before `save-off` is sent, so a lost reply is still undone; `send_command_strict` refuses a screen fallback; `save-all flush` with a configurable timeout; auto-save re-enabled right after the copy rather than after compression (backup.sh:227-230). Good design.
- Staging then compress then validate then publish, EXIT trap removing partial archive and staging.
- Restore: staging next to the server, rename swap with `swap_recover`, two server-stopped checks, owner check on the archive, unit review before sudo install, no implicit "newest archive" without a TTY.
- Exit code 75 convention for "skipped" is consistent across backup, restore, restart, cleanup.
- Cleanup never deletes the newest valid archive of a tier, uses filename timestamps, and tolerates per-file delete failures.

What is weak:
1. Failure signalling is inconsistent (B7). Only some failure paths notify; `set -e` aborts are invisible except in the cron log.
2. No success/failure state file. There is no `last_success` marker, so monitoring ("no good hourly backup in 3 hours") has to parse logs. run_backup's flag files are per-slot, not a health signal. Add `$BACKUP_BASE/.last_backup.json` (time, tier, size, duration, exit) and have the wrapper/doctor read it.
3. No integrity record beyond decompress-and-list. A SHA-256 sidecar written after validation would let restore, cleanup (`protected_archive`) and offsite sync verify cheaply and detect later bit-rot (P3).
4. Validation proves "the tar is readable", not "the tar contains the world". There is no sanity check on contents (for example `level.dat` and at least one region file present, size within X% of the previous backup). A save-off failure mode that produces an empty world dir would still pass.
5. Recovery path: restore leaves nothing to fall back to by default (B1); `--keep-old` keeps one generation but the doc calls it "off by default".
6. Logging: backup writes to stdout only, with its own `log()`; cleanup's `log` is a different format (`[date] msg` without level, cleanup_backups.sh:9-11); restore uses raw `echo "[INFO]"`. Three formats, no rotation, no file in a known place besides the cron redirect.
7. Cross-platform (Windows Git Bash tests): GNU-only `find -printf`, `stat -c`, `du -sb`, `realpath -e`, `date -d`, `chmod --reference`, `ionice` are used directly in production scripts. They work on Linux; tests rely on shims (`tests/shell/shims/du`, `rsync`, `tar`, `zstd`, `flock`).

---

## 5. Test coverage gaps

Existing coverage is broad for the happy paths and for several injected failures (`tests/shell/test_backup.sh`: 31 cases; `test_restore.sh`: 33; `test_cleanup.sh`: 19). Gaps, in rough priority order:

1. **The shims hide real tool behaviour.** `tests/shell/shims/rsync` is a `cp -a` stand-in that ignores all excludes (its own header: "Excludes are ignored"), so the exclude list in `backup.sh:192-203`, `--inplace`, symlink handling (B10) and the `*.jar` hourly exclusion are never exercised by `test_backup.sh`. `shims/zstd` is gzip, so `-T0`, level handling (13d), `--long`, and real frame-checksum failure detection are not tested. No test runs against real `rsync`/`zstd`/`tar` even on Linux CI.
2. **Signals and abnormal termination of backup/restore.** `tests/shell/lib/signals.sh` is used only by `test_guided_route.sh` and `test_wizard_config.sh`. There is no test that sends SIGTERM/SIGINT during rsync or compression and asserts save-on is sent, staging is removed, and the lock is released; none for a restore killed between the two renames (`swap_recover`), the code path S-031 added.
3. **Ownership and permission outcomes of restore** (B3), and restore under sudo/root.
4. **Race tests:** a start racing the swap (partly covered by `TAR_SHIM_START_SERVER` and `test_restore_rechecks_right_before_the_swap`), a file replaced between `archive_is_trusted` and extraction (B6), an archive appearing under `.part`/in-progress name while listed (B4).
5. **Retry semantics of `run_backup.sh`:** no test that a skipped/failed 00:20 run is retried (B5) or that Sunday/first-Sunday sequences produce the expected archive kinds (P5). `test_run_backup_*` cases cover only a few flag conditions.
6. **Disk full:** `test_a_failed_backup_still_runs_cleanup` simulates failure generically; there is no ENOSPC injection in rsync/zstd/cp (staging, jar carry-over, `.mc-meta` rsync) and no preflight test (B11).
7. **Notifications on failure paths** (B7): no assertion that rsync failure or a `set -e` abort calls the webhook, nor that `wait_for_notifications` is reached.
8. **Cleanup:** `prune_orphan_jars` cost/guard (P1), an empty `jars/` directory, an unreadable archive during storage eviction, decimal/invalid `MAX_STORAGE_GB`, `protected_archive` skipping a corrupt newest archive in the eviction loop, concurrent cleanup vs download.
9. **Restore data-loss semantics:** nothing asserts what happens to excluded files (B2) or that `.mc-meta` of the live tree survives a failed restore (13j); `--ago` with ties/far targets and filename-vs-mtime disagreement (13i).
10. **`nice_run` fallbacks** (B8): no test with an `ionice` shim that exits non-zero, nor with only one of `nice`/`ionice` present.
11. **Archive content safety:** `mk_symlink_archive.js` exists (symlink escape for the *backup file path*), but no test extracts an archive with `..`, absolute, or symlink-then-write members.
12. **`migrate-lib/backup.sh`:** no test that a failed `tar` leaves no archive or that prune does not count a truncated one (13q); `scheduled_restart.sh` exit-75 behaviour; `create_backup_job.sh` idempotence with a differently quoted path and cron `PATH`.
13. **Windows/MSYS:** tests that need real `flock` or symlinks skip themselves; consider a one-line summary of skipped count in `run.sh` so a green Windows run is not mistaken for full coverage.

---

## 6. Suggested order of work

1. B1 (default keep-old or automatic pre-restore archive), B2.
2. P1 (cheap, large win), B4 (`.part` + rename), B5 (daily retry), B9 (trap order), B7 (single failure notifier), B8 (probe ionice).
3. P2 + P4 (persistent staging mirror, thread/IO tuning), B11 (space preflight and pre-eviction), B12 (timeout + start-of-run save-on).
4. B6 (fd-based trust check), B3, path-member scan, P3/P6 tuning.
5. Tests: real-tool CI job on Linux, signal tests for backup/restore, ENOSPC injection, run_backup scheduling table test.
