# Backup and restore audit: consolidated report and upgrade blueprint (Agent 3)

Inputs: `backup-audit-agent1-code.md` (code findings), `backup-audit-agent2-research.md` (practices and tools), and a fresh read of `src/scripts/backup/backup.sh`, `restore.sh`, `automation/run_backup.sh`, `automation/cleanup_backups.sh`, `src/scripts/common/archive_restore.sh`, `utils.sh` (locks), `server_control.sh` (save path), `webhook.sh`, `load_variables.sh`, `src/setup/management/create_backup_job.sh`, `service_user.sh` (sudoers shapes), `migrate-lib/backup.sh`, `rollback.sh` (callers), `variables.example.json`, the test shims and CI workflow, and `docs/backup-restore.md`. Nothing was changed in the repo. Two behaviours were checked by running them in Git Bash 5.3 on this machine (EXIT trap on SIGTERM; availability of GNU tool flags). Nothing was benchmarked.

"Verified" in this report means: I read the cited lines myself and the failure follows from them. "Partly" means the code path is confirmed but the trigger depends on host behaviour I could not reproduce. "No" means I did not confirm it.

---

## 1. Executive summary

The backup system is better than average for hand-rolled Bash: it does a confirmed `save-off` / `save-all flush`, re-enables saving before compression, validates archives, restores through a staging directory with a rename swap, and has a consistent exit `75` skip convention. Agent 2's concern that the repo might copy after a plain `save-all` is unfounded (`server_control.sh:351-364`).

The real problems fall into three groups:

1. **Data-loss risks on restore.** A restore deletes the previous server tree by default (no prompt on the wrapper path), and also wipes logs, crash reports and `ledger.sqlite`, which the backup never contained. This is the single most important fix.
2. **Avoidable cost on every hourly run.** The shipped default `COMPRESSION_LEVEL` is `15` (`variables.example.json:6`) and it applies to the hourly tier with `-T0` (all cores). The full world copy runs inside the save-off window. On legacy installs, cleanup decompresses every archive every hour to look for orphaned jars. These three items are most of the CPU, disk and stall time the system costs the game server.
3. **Silent-failure paths.** No watchdog (a hung step stops all backups silently), a missed or failed midnight daily is never retried and Sundays never get a daily, several failure exits send no webhook, the archive is visible under its final name while still being written, and there is no space preflight.

Recommended direction: stay pure Bash (no borg/restic as a default dependency), keep the archive file format and every entry point path and CLI shape (the sudoers grant in `service_user.sh:127-137` pins them), and add a small `backup/lib/` layer: probed priority wrapper, persistent rsync mirror (or reflink snapshot) as staging, one-pass verify, `.part` publish with a sidecar checksum, a pure scheduling function, a supervisor with timeout in `run_backup.sh`, and a status file. Restore keeps the old tree by default.

### Ranked findings (de-duplicated)

Severity is for this project's production profile (one Linux host, cron, API wrapper as a second user). Source IDs refer to Agent 1 (P*, B*) and new findings from this pass (N*).

| ID | Sev | Source | File:line | Verified | Finding |
|----|-----|--------|-----------|----------|---------|
| F01 | High | B1 | `common/archive_restore.sh:191`, `backup/restore.sh:203` | yes | Restore deletes the previous server tree unless `--keep-old`; the wrapper cannot pass `--keep-old` (sudoers shapes `service_user.sh:136-137`), so every wrapper restore is irreversible. `--ago` picks the closest mtime in either direction with no distance limit (`restore.sh:147-152`). |
| F02 | High | N1, P4 | `variables.example.json:6`, `backup/backup.sh:293,302` | yes (config); impact [kb] | Hourly archives compress at the configured level, shipped as `15`, with `-T0`. zstd 15 is roughly an order of magnitude slower than level 3 for a few percent of ratio on already-deflated region data. This is the main CPU stall the comment in `create_backup_job.sh:24-28` describes. |
| F03 | High | P2 | `backup/backup.sh:172-230` (`rm -rf` 211, rsync 220) | yes | Staging is emptied and re-copied from scratch every run, inside the save-off window. `--inplace` into an empty dir and `sleep 2` after a confirmed flush are useless. |
| F04 | High (legacy installs) | P1 | `automation/cleanup_backups.sh:200-231` | yes | `prune_orphan_jars` decompresses and lists every archive in every tier whenever a `jars/` dir exists, before checking whether any jar is even old enough to delete. Runs after every hourly backup, un-niced, listing held in a shell variable. |
| F05 | Medium | B7 | `backup.sh:220-223`, `314-316`, `329-331`; any `set -e` abort | yes | rsync failure and every `set -e` abort exit with no webhook; two failure exits skip `wait_for_notifications`. |
| F06 | Medium | B5, P5 | `automation/run_backup.sh:76-82` | yes | Daily is only attempted when `HOUR == 0`: a failed or skipped 00:20 run loses that day's daily, and every Sunday gets weekly (and on the first Sunday also monthly) but never a daily. First Sunday runs two full level-15 archives in consecutive hours. |
| F07 | Medium | B2 | `backup.sh:192-199` vs `archive_restore.sh:163-192` | yes | Restore replaces the whole tree, so files the backup excludes (`logs/`, `crash-reports/`, `ledger.sqlite`, `*.gz`) are destroyed and not restored. |
| F08 | Medium | B12 | `create_backup_job.sh:30`, `run_backup.sh:56-58` | yes | No timeout anywhere. A hung RCON/rsync/zstd keeps both locks; every later run exits 75 and is logged as WARN only. No alert on repeated skips. |
| F09 | Medium | B4 | `backup.sh:295-305` | yes | zstd writes straight to the final name. Cleanup, restore and rollback are lock-protected, but anything else (the wrapper's file listing, an offsite sync) sees a growing file for minutes. Wrapper behaviour not verified (separate repo). |
| F10 | Medium | B11 | `backup.sh` (no `df` anywhere), `cleanup_backups.sh:246-288` | yes | No free-space preflight; eviction runs only after a backup has already failed with ENOSPC. Costs at least one lost backup per overflow. |
| F11 | Medium | B6 | `restore.sh:169` -> `178` -> `183` -> `197` | yes (by reading) | Trust check (owner uid) is on the path; validation and extraction reopen the path later, across an unbounded interactive prompt. The S-004 adversary (wrapper user with write access to backups) can swap the file. |
| F12 | Medium | B9 (corrected) | `backup.sh:17-31` | yes | EXIT trap deletes the multi-GB staging tree before it sends `save-on`. Agent 1's second point (lock released before cleanup) only applies to the `mkdir` fallback: with `flock`, `release_operation_lock` is a no-op (`utils.sh:135-140`) and the lock lives until process exit. |
| F13 | Medium | B8 | `backup.sh:46-54`, `cleanup_backups.sh:16-24` | partly | `command -v ionice` does not prove `ionice` works. util-linux `ionice` exits non-zero without running the command when `ioprio_set` is refused unless `-t` is given [kb], which would fail every rsync and tar. Also fails when `ionice` exists but `nice` does not. |
| F14 | Medium | P3 | `backup.sh:327`, `archive_restore.sh:47-48,69`, `cleanup_backups.sh:86,115,267` | yes | Backup decompresses the new archive twice; restore three times before the first byte lands; cleanup runs `zstd -t` (un-niced) on the newest archive of each tier it thins. |
| F15 | Medium (conditional) | B10 | `backup.sh:186-189,220` | yes (rsync `-a` implies `-l`) | A top-level symlink (`world -> /mnt/fast/world`) is archived as a dangling link; validation passes. |
| F16 | Medium | B12 sub-item | `backup.sh` include list | no | Live plugin databases (SQLite/H2) are not frozen by `save-off`; a torn copy validates as tar. No per-install exclude or dump hook exists. |
| F17 | Low-Med | N2 | `backup.sh:220` | yes | rsync exit `24` ("some files vanished") fails the backup, although it is harmless for a live server dir. |
| F18 | Low-Med | B13h, B13i, N3 | `restore.sh:142-152` | yes | Selection uses `-maxdepth 2 -name '*.tar.*'`: matches `hourly/tmp_backup/...` data files today, and would match any `.part` or sidecar file a fix introduces. Missing tier dir aborts under `pipefail` before the friendly error. Orders by mtime while cleanup orders by filename stamp. **Must be fixed before or together with F09.** |
| F19 | Low | B3 (downgraded) | `archive_restore.sh:65-67,169` | yes | Only when an admin runs restore as root by hand: the new server root is root-owned. The wrapper runs restore as the server owner (`service_user.sh:152`, `($owner)`), not root, so Agent 1's Medium is too high. |
| F20 | Low | N4 | `webhook.sh:104-109`, `utils.sh:108`, `backup.sh:137` | yes (by reading) | Backgrounded `curl` inherits lock fds 7 and 9. If the script exits without waiting (F05), the `flock` stays held up to 10 s and an immediately following run exits 75. |
| F21 | Low | B13j | `restore.sh:193` | yes | The EXIT trap removes `<server>/.mc-meta` on every exit, including a failed restore of the untouched live tree (normally harmless: live trees have none). |
| F22 | Low | B13k | `archive_restore.sh:191` | yes | Interrupt during `rm -rf "$old"` orphans `<server>.pre-restore.<pid>` forever. |
| F23 | Low | B13b | `backup.sh:98,101` | yes | "Starting backup" is broadcast before the lock, so skipped (75) and `--dry-run` runs announce it to players. |
| F24 | Low | B13d, B13o, B13p | `backup.sh:299-302`, `cleanup_backups.sh:132-135,247,252` | yes | No numeric validation of `COMPRESSION_LEVEL` / `MAX_STORAGE_GB` in Bash (only setup-time in `loadVariables.js:57-69`); a decimal `MAX_STORAGE_GB` aborts cleanup in an arithmetic expansion; one bad tier value `exit 1`s the whole cleanup. |
| F25 | Low | B13a, B13g | `backup.sh:35-39,73`, `create_backup_job.sh:30` | yes | Three log formats (backup, cleanup, restore); `backup.log` grows unbounded; `--verbose` is a no-op. |
| F26 | Low | B13r | `create_backup_job.sh:30` | no | Cron line sets no `PATH`; `node` (RCON), `zstd` or `rsync` outside `/usr/bin:/bin` would break saves. Depends on how Node was installed. |
| F27 | Low | B13n | `automation/scheduled_restart.sh:20-23` | yes | A restart that collides with a backup is skipped for the cycle with only a WARN. Shrinks automatically once backups are fast (F02, F03). |
| F28 | Low | B13 (restore race) | `restore.sh:202-203` | partly | Nothing blocks a `systemctl start` between the second stopped-check and the swap; window is milliseconds. |
| F29 | Low | B13q | `migrate-lib/backup.sh:13-23` | yes | Migration archive written to final name, never listed; a truncated one counts toward "newest N". |
| F30 | Low | B13c | `backup.sh:186-189` | yes | Top-level names starting with `-` would be parsed as rsync options. |
| F31 | Low | N5 | `docs/backup-restore.md:9,34` | yes | Docs say backups "run unlocked" without `flock` (the operation lock's `mkdir` fallback still serializes them) and still describe archives linking jars into `jars/` (removed by S-002). |

Corrections to the research inputs:
- Agent 2 claims default SIGTERM death skips the EXIT trap. Tested on Bash 5.3: the EXIT trap ran and the status was 143. The real caveat is that Bash defers the trap until the current foreground child exits, so a TERM sent only to the script (not its process group) waits for a running rsync or zstd. Explicit `INT TERM HUP` traps are still worth adding for determinism and exit codes.
- Agent 2's portability worry is mostly about macOS, which is out of scope. Git Bash ships GNU coreutils and findutils: `stat -c`, `find -printf`, `df --output`, `du -sb`, `realpath -e`, `date -d`, `cp --reflink=auto`, `nproc`, `timeout`, `sha256sum` all work there (tested). Missing on Windows: `flock`, `ionice`, reflink support, and (on this machine) `zstd` and `rsync`.
- Agent 2's `sync` step before copy is not needed for a file-level copy (reads go through the page cache); it matters only for block-level snapshots.
- Agent 2's ranked pattern 5 ("switch default compressor to zstd") is already done; the open question is level and threads, not the tool.

---

## 2. Recommendations

### 2.1 Performance and speed

**R-P1. Lower the hourly level and cap threads (F02).** Hourly uses `BACKUP_HOURLY_LEVEL` (default: `COMPRESSION_LEVEL`, so nothing changes silently), archives use `BACKUP_ARCHIVE_LEVEL` (default `max(COMPRESSION_LEVEL, 15)`, today's rule). Change the shipped default in `variables.example.json` and the wizard to `3` for new installs. Add `BACKUP_ZSTD_THREADS`, default `max(1, min(4, nproc / 2))`; `0` means today's `-T0`. Region files are zlib level 1 per chunk, so outer compression gains are small at any level; level 3 versus 15 should cost a few percent of size and save most of the CPU time [kb]. Measure this instead of trusting it: ship `backup/tools/bench_levels.sh` that runs `zstd -b3 -e19 -T<n>` on a tar of the mirror (zstd's built-in benchmark mode, no extra tools) and prints ratio and MB/s per level. Skip `--long` and `--ultra`: unmeasured benefit, extra decoder memory, and `--long` above 27 makes old archives unreadable without a flag.

**R-P2. Shrink the save-off window with persistent staging (F03).** Replace "empty `tmp_backup`, copy everything" with a staging strategy chosen by `BACKUP_STAGING_MODE`:
- `mirror` (default when reflink is unavailable): a persistent `$BACKUPS_PATH/.stage/mirror`, refreshed by `rsync -a --delete --numeric-ids` (no `--inplace`). After the first run only changed files are copied, so save-off lasts seconds on a mostly idle world. Jars are always mirrored (they rarely change); the hourly `*.jar` exclusion moves to the `tar` step. A marker `.stage/MIRROR_INCOMPLETE` is written before the rsync and removed after success; tar refuses a mirror that has it. A killed rsync is healed by the next `--delete` run.
- `reflink`: `cp -a --reflink=always` into a fresh `.stage/snap` when a probe clone succeeds (same filesystem, XFS or btrfs). Near-instant copy under save-off, no permanent extra disk.
- `fresh`: today's behaviour, for very tight disks.
- `auto`: `reflink` if the probe passes, else `mirror`.

Never use hardlinks for staging: region files are rewritten in place, so a hardlinked "copy" changes after `save-on`.

Mirror caveat to handle explicitly: rsync's quick check compares size and mtime. Region files are sector-padded, so size often does not change; a write landing in the same wall-clock second as the previous mirror copy of that file could be skipped next time [kb, low probability]. Mitigation: archive (daily and above) runs use `--ignore-times` so the mirror is fully re-verified at least daily, and the implementation task records `rsync --version` and uses nanosecond comparison if that rsync supports it (verify the flag on the target version before relying on it).

Also drop `sleep 2` (the flush is already confirmed) and re-check after the copy that the server did not go from stopped to running mid-copy (discard and fail that run).

**R-P3. One decompression pass everywhere (F14).** Backup: verify with a single `zstd -dc part | tar -tf -` under `pipefail` (zstd checks the frame checksum, so `zstd -t` first is a duplicate read), and use that listing for a content sanity check: at least one `*/level.dat` and one `*/region/*.mca` must be present, else the archive is rejected. Restore: no separate validation pass; extract once from the trusted fd into staging (extraction failure is validation failure, the live tree is untouched), then inspect staging. Three passes become one.

**R-P4. Make cleanup cheap (F04, F14).**
- `prune_orphan_jars`: compute the candidate jar list first and return if empty; `rmdir` an empty `jars/`; run the archive scan at most once per day (flag in `.backup_flags`); stream the listing into `sed` instead of a variable; wrap in `nice_run`.
- `protected_archive`: treat an archive as valid when its sidecar exists, is newer than the archive and the archive is non-empty. Only legacy archives without a sidecar fall back to a niced `zstd -t`, and a pass writes a "verified" sidecar (without hash) so it happens once per archive, at most two per cleanup run.

**R-P5. Build tier archives once (F06).** When several archive tiers are due in the same run (daily plus weekly plus monthly on the first Sunday), build one archive at the archive level and hardlink it into every due tier directory (fallback `cp --reflink=auto`, then `cp`). Archives are immutable after publish, so hardlinks are safe here (unlike staging). Eviction must then count only bytes it actually frees: a file with link count above 1 frees nothing (`stat -c %h`), see R-S3.

**R-P6. I/O and CPU priority that actually applies (F13, P4).** Probe once per run: `ionice -c2 -n7 -t true` and `nice -n 10 true`, build the wrapper array from what works. Use `-t` so a refused ioprio never fails the command. Be honest in the comments: `ionice` only has an effect under BFQ; on `mq-deadline`/`none` (typical NVMe and virtio) the real levers are fewer zstd threads, a lower level and less data copied, which R-P1 and R-P2 deliver. A `systemd-run --user --scope -p CPUWeight= -p IOWeight=` path is possible but unreliable from cron (needs a user manager, lingering and IO controller delegation); keep it out of scope unless the project moves to a systemd timer.

### 2.2 Stability and reliability

**R-S1. Atomic publish (F09, F18).** Write `<tier>/.minecraft_backup_<stamp>.tar.zst.part` (leading dot: invisible to `minecraft_backup_*` globs in cleanup and rollback, and to `upgrade-server.js:421`'s `/\.tar\.(zst|gz)$/`). After verification: write the sidecar via tmp plus `mv`, then `mv -T part final` (same directory, atomic). Stale `.part` files are removed at the start of the next locked run. Restore's selection is changed first to `-maxdepth 1` and `-name 'minecraft_backup_*.tar.zst' -o -name 'minecraft_backup_*.tar.gz'` (with `archives/*/` for `--archive`), ordered by filename stamp like cleanup. Sidecars live in `$BACKUPS_PATH/.meta/<tier>/<name>.sha256`, not next to the archive, so no existing listing (including the external wrapper, unverified) ever sees them.

**R-S2. Trap order, signals, single failure notifier (F05, F12, F20).**
- EXIT handler order: (1) `save-on` if `_AUTO_SAVE_DISABLED`, (2) remove `.part`, (3) remove per-run staging (never the mirror), (4) on a non-zero, non-75 status with no notification sent yet: `notify_error backup_failed "<stage>: <reason>"`, (5) `wait_for_notifications`, (6) release the `mkdir` lock if one is held (the `flock` fd closes at exit).
- `trap 'exit 130' INT`, `trap 'exit 143' TERM`, `trap 'exit 129' HUP`, so every signal goes through the EXIT handler with a stable code.
- A `BK_STAGE` variable (`preflight`, `quiesce`, `stage`, `compress`, `verify`, `publish`) is set as the run advances, so the single notifier can say where it failed. Per-site `notify_error` calls go away.
- Background `curl` gets `7>&- 9>&-` so it never holds a lock.

**R-S3. Space preflight and pre-eviction (F10).** Before staging: estimate need. Mirror mode needs roughly the delta plus one archive; fresh mode needs the server size plus one archive. Use the last archive size from `last_backup.json` times 1.2 as the archive estimate (fallback: `du -sb` of the include set divided by 2). Compare with `df --output=avail -B1 "$BACKUPS_PATH"` minus `BACKUP_SPACE_MARGIN_PCT` (default 5). If short, run `cleanup_backups.sh --make-room <bytes>` (eviction in the existing tier order, still never the newest valid of a tier). If still short, fail with exit `73` and a `backup_failed` webhook naming the shortfall. Eviction's arithmetic subtracts a file's size only when its link count is 1.

**R-S4. Watchdog and self-healing (F08, F26).** `run_backup.sh` becomes the supervisor, so the crontab line does not change:
- export a sane `PATH` (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` plus the directory of the `node` found at setup time if recorded);
- run `backup.sh` under `timeout --signal=TERM --kill-after=120 "${BACKUP_TIMEOUT_MINUTES:-120}m"`. GNU `timeout` signals the child; `backup.sh`'s TERM trap then runs the EXIT handler;
- on `124` or `137` (killed), send `save-on` itself if the server is up (idempotent; "already on" is harmless), notify `backup_failed` with "timed out", record the failure;
- count consecutive `75` exits in `.backup_flags/skip_streak`; at `BACKUP_SKIP_ALERT_AFTER` (default 3) send `notify_warning backup_skipped` once per streak;
- rotate `backup.log` copy-truncate style (`cp` then `: >`, safe with cron's `>>` O_APPEND) above `BACKUP_LOG_MAX_MB` (default 10), keep 3.

**R-S5. Retry logic (F06).** Keep retries at slot level, not inside steps. Retrying rsync or zstd inside one run only lengthens save-off, and their failures (ENOSPC, I/O error) are not transient on a second's timescale. Save commands already have one confirmed attempt with `SAVE_TIMEOUT_SECONDS`; leave that. Rules:
- an archive tier is due for the whole calendar day until it succeeds (daily from 00:00, weekly on Sunday, monthly on the first Sunday), capped at `BACKUP_ARCHIVE_MAX_ATTEMPTS` (default 3) failed attempts per tier per day, then one `backup_failed` webhook "giving up for today";
- when an archive attempt fails (not 75), the same run immediately makes an hourly backup so coverage has no gap (cheap with the mirror);
- every due tier is satisfied by the one archive (R-P5), so Sunday gets a daily too.

**R-S6. Restore safety (F01, F07, F11, F19, F21, F22).**
- Keep the old tree by default as `<server>.pre-restore` (one generation; decision D2). New `--discard-old` opts out; `--keep-old` stays accepted as a no-op. Cleanup removes a `.pre-restore` older than `RESTORE_KEEP_OLD_DAYS` (default 7). Peak disk use does not grow: today the old tree also coexists with staging until the final `rm -rf`.
- Before the swap, copy `RESTORE_CARRY_OVER` (default `logs crash-reports ledger.sqlite`, decision D5) from the live tree into staging when staging lacks them.
- TOCTOU: open once, check the opened inode, use the same fd for everything: `exec {fd}<"$file"`, `stat -L -c '%u %h' "/dev/fd/$fd"` (owner must be the running user or root; reject link count above 1 unless the link is inside `$BACKUPS_PATH/archives`, since R-P5 makes legit hardlinks), then `zstd -dc <&"$fd" | tar -xf - -C "$staging"`. The confirmation prompt happens after the open, so a swap during the prompt changes nothing.
- After extraction, scan staging: reject the restore if any symlink target is absolute or escapes staging, except legacy jar links matching `*/jars/*.jar` (archives made before S-002 contain those and `complete_staged_jars` repairs them). GNU tar already refuses `..` members and strips leading `/` by default.
- `--ago`: choose by filename stamp, prefer the newest backup at or before the target, and refuse a match more than 50 percent of the requested distance away unless `--y` was given interactively. Print the chosen archive's stamp next to the requested time.
- When running as root: `chown --reference="$server" "$staging"` next to the existing `chmod`.
- Remove `.mc-meta` only on the success path. Rename the old tree to a trash name and delete it after the swap with a trap that re-attempts on interrupt (or simply rely on keep-old as the default).
- Optional, P4: a `<server>.restoring` marker that `start.sh` refuses to start through, removed by the restore EXIT handler (F28).

**R-S7. Smaller hardening.** Treat rsync `24` as a warning (F17). Follow top-level symlinks in the include list (`BACKUP_FOLLOW_SYMLINKS`, default `true`, with an INFO line naming the target) (F15). `BACKUP_EXTRA_EXCLUDES` for plugin DBs, documented with the advice to use the plugin's own dump (F16). Prefix includes with `./` and pass `--` (F30). Move the "Starting backup" broadcast after lock acquisition and skip it in `--dry-run` (F23). Validate numeric config in Bash with clear messages, log and skip a bad tier instead of `exit 1` (F24). Wire `--verbose` to `rsync -v`/`tar -v` or remove it (F25). Keep the existing excludes unanchored: anchoring `logs/*` would start including plugin log directories, a silent content change for no safety gain.

### 2.3 Storage optimization

**zstd levels and threads.** Covered in R-P1. Expectation to verify with the bench script: on a modded world, hourly level 3 versus 15 changes archive size by single-digit percent [kb]. Archive tiers can stay at 15 (they are built once per day and, with R-P5, once per due set) but with capped threads.

**Dedup options, honestly assessed:**

| Option | Gain on this data | Cost for this project | Verdict |
|---|---|---|---|
| Hardlink identical tier archives (R-P5) | Removes the duplicate daily/weekly/monthly copy made on the same day: up to 2 full archives per Sunday | Pure Bash, eviction must respect link counts | **Adopt.** |
| Hardlink staging | None safely (in-place region writes) | Corrupts snapshots | **Reject.** |
| reflink staging (R-P2) | Not a storage saving, a save-off window saving | Only XFS/btrfs | **Adopt as optional fast path.** |
| `rsync --link-dest` dated trees | File-level only. A region file with one changed chunk is stored whole; saves only cold regions. Stored uncompressed (region data is deflate level 1 already, so the loss is moderate) | Changes the backup format from files to directories: restore, rollback, cleanup, `prune-chunks.js --backup`, upgrade's `listArchives` and the external wrapper's list/download/restore API all assume archive files | **Reject** for now: high compatibility cost, unproven gain. |
| restic / borg / kopia | Block-level dedup is the only option that saves storage on actively played worlds; no published Minecraft numbers (Agent 2, section 2.3) | New binary on every host, repo locking and maintenance (`prune`, `check`), a second restore path, the wrapper API would need a new model; secrets handling for repo passwords | **Do not adopt as default.** At most an optional post-publish export hook (decision D1). |
| ZFS/btrfs snapshots | Huge for both window and storage where present | Host dependent; the project cannot assume them | Out of scope beyond reflink detection. |

**Retention policy.** The current scheme (count caps per tier, storage cap with tier-ordered eviction, newest valid per tier protected, filename-stamp ordering) is sound GFS and should stay. Changes:
- eviction and count caps skip `.part`, ignore `.stage/` and `.meta/` in `du`, and account for hardlinks (R-S3);
- `--make-room <bytes>` mode for the preflight;
- `MAX_STORAGE_GB` validated as an integer;
- `.pre-restore` expiry via `RESTORE_KEEP_OLD_DAYS`;
- document the defaults' coverage: with the shipped `MAX_HOURLY_BACKUPS=3`, an operator noticing grief 4 hours later has only dailies left. Recommend 24 hourly for new installs once hourly archives are cheap (level 3, no jars), and say so in the wizard text. This is a recommendation, not a silent change.

---

## 3. Decision points for the user

| # | Decision | Options | Recommendation |
|---|----------|---------|----------------|
| D1 | External dedup tool | (a) pure Bash only; (b) optional restic export hook after publish; (c) restic/borg as primary store | **(a) now, (b) later if measured storage growth justifies it.** Run the bench and 4 consecutive hourly copies through `restic backup --verbose` once, by hand, before deciding. (c) breaks the wrapper's file-based API. |
| D2 | Restore keeps the old tree by default (behaviour change for CLI, wrapper and `rollback.sh`) | (a) keep `<server>.pre-restore` by default, `--discard-old` to opt out, expiry after 7 days; (b) take an automatic `--archive pre-restore` backup first (slow: a full level-15 compress while the server is down); (c) keep today's default, only document | **(a).** Zero extra time, no extra peak disk, and the wrapper gets it without a sudoers change. The cost is one server copy of disk for up to 7 days; `RESTORE_KEEP_OLD=false` restores today's behaviour. |
| D3 | Default staging mode | (a) `auto` (reflink, else persistent mirror); (b) `fresh` (today); (c) mirror only | **(a).** The mirror permanently costs about one server size on the backups filesystem (today that space is used transiently every hour anyway). Installs with no headroom set `fresh`. |
| D4 | Hourly compression level for existing installs | (a) honour `COMPRESSION_LEVEL` (default unchanged), new installs default to 3, `doctor.sh` suggests lowering; (b) force hourly to 3 everywhere | **(a).** Explicit configuration wins; the thread cap (`BACKUP_ZSTD_THREADS`) is applied to everyone because it is benign. |
| D5 | What restore carries over from the live tree | (a) `logs crash-reports ledger.sqlite`; (b) logs and crash reports only; (c) nothing (rely on D2's kept tree) | **(a).** None of these exist in any backup, so not carrying them over means losing them. `ledger.sqlite` will describe events newer than the restored world; that is what an admin investigating grief needs. Configurable via `RESTORE_CARRY_OVER`. |
| D6 | Scheduler | (a) keep cron with the in-script supervisor; (b) move to a systemd timer with resource controls | **(a).** No crontab or unit migration for existing hosts. Revisit (b) only if real CPU/IO caps become necessary. |
| D7 | Hourly coverage defaults for new installs | `MAX_HOURLY_BACKUPS` 3 (today) vs 24 | **24** once Phase 3 lands, with `MAX_STORAGE_GB` as the guard. |
| D8 | Rollback (`rollback.sh`) prepares staging while the server still runs, then stops, swaps and starts | (a) yes; (b) no, keep order | **(a)** for `rollback.sh` only (it already validates before stopping). `restore.sh` keeps its early "server must be stopped" exit 3, which the wrapper relies on. |

---

## 4. Blueprint for the upgraded architecture

### 4.1 Principles and compatibility constraints

- Entry points, their paths and their argument shapes stay: `backup/backup.sh [--archive [type]] [--dry-run] [--verbose]`, `backup/restore.sh --file <abs> --y [--archive]`, `rollback.sh [--y] [--keep-old] [--list]`, `automation/run_backup.sh`, `automation/cleanup_backups.sh`. The sudoers grant (`service_user.sh:127-137`) and the crontab line need no change. New flags are optional and never required by the wrapper.
- Archive names (`minecraft_backup_YYYY-MM-DD_HH-MM-SS.tar.zst`), tier directories, `.tar.gz` read support, legacy jar-link archives and `.mc-meta` layout stay.
- Every new config key is optional, defaulted in Bash, and also accepted as an optional `BACKUPS.*` key in `variables.json` (written to `variables.txt` only when set).
- Pure Bash plus coreutils, findutils, tar, zstd, rsync. `flock`, `ionice`, reflink and `timeout` are probed; each has a fallback. Every function that touches a GNU-only flag lives in `backup/lib/` so tests can shim it.

### 4.2 File and module layout

```
src/scripts/backup/
  backup.sh                    entry point; orchestration only (~150 lines)
  restore.sh                   entry point; orchestration only
  automation/run_backup.sh     supervisor: schedule, preflight, timeout, fallback, cleanup
  automation/cleanup_backups.sh retention; gains --make-room <bytes>
  lib/bk_common.sh             logging, exit codes, config defaults and validation, priority probe
  lib/bk_stage.sh              staging modes (mirror, reflink, fresh), metadata staging
  lib/bk_archive.sh            compress to .part, verify, sidecar, publish, tier links
  lib/bk_space.sh              estimate, available, preflight
  lib/bk_state.sh              last_backup.json, skip streak, attempt counters, flags
  lib/bk_schedule.sh           pure due-tier computation
  tools/bench_levels.sh        zstd level/thread benchmark on the current mirror
src/scripts/common/archive_restore.sh   extended (fd-based open/extract, staging scan, carry-over); old signatures kept
```

Runtime layout under `$BACKUPS_PATH`:

```
hourly/minecraft_backup_<stamp>.tar.zst
hourly/.minecraft_backup_<stamp>.tar.zst.part      only while a run is in flight
archives/{daily,weekly,monthly,update,general,<custom>}/minecraft_backup_<stamp>.tar.zst
.stage/mirror/                 persistent staging (mirror mode)
.stage/snap/                   per-run snapshot (reflink or fresh mode)
.stage/meta/.mc-meta/          per-run metadata for archive runs
.stage/MIRROR_INCOMPLETE       present while the mirror is being refreshed
.meta/<tier>/<name>.sha256     sidecar ("<hex>  <name>", or "verified-legacy" for migrated archives)
.meta/last_backup.json         status of the last run
.backup_flags/                 existing per-day flags, plus attempts_<tier>_<date>, skip_streak, jarscan_<date>
.backup.lock                   existing
jars/                          legacy, removed once empty
```

### 4.3 Function-level interfaces

All functions return non-zero and log instead of exiting, except `bk_die`. Output on stdout only where stated.

`lib/bk_common.sh`
- `bk_log <LEVEL> <msg...>`: LEVEL in `DEBUG INFO WARN ERROR SUCCESS`; writes the format in 4.6 to stdout (and stderr for WARN/ERROR when `BK_LOG_STDERR=1`). Replaces the three local `log()` definitions.
- `bk_die <exit-code> <msg>`: logs ERROR, sets `BK_FAIL_REASON`, exits.
- `bk_load_config`: applies defaults for every key in 4.4 and validates them; invalid optional keys fall back to the default with a WARN, invalid required ones (`COMPRESSION_LEVEL` not 1-19) return 1.
- `bk_probe_priority`: fills the array `BK_NICE` once (`ionice -c2 -n7 -t nice -n 10`, or a subset, or empty) after test-running each part with `true`.
- `bk_nice <cmd...>`: `"${BK_NICE[@]}" "$@"`.
- `bk_zstd_threads`: prints the effective `-T` value.
- `bk_set_stage <name>`: sets `BK_STAGE` for the failure notifier.

`lib/bk_stage.sh`
- `bk_stage_select`: prints `mirror|reflink|fresh` from `BACKUP_STAGING_MODE` and a reflink probe (`cp --reflink=always` of a 1-byte file from `SERVER_PATH` into `.stage`).
- `bk_stage_build_includes <server_dir>`: fills `BK_INCLUDES` with `./name` entries (nullglob, dotglob; skips `backups`, `.mc-meta`); resolves top-level symlinks per `BACKUP_FOLLOW_SYMLINKS`.
- `bk_stage_refresh <mode> <server_dir> <full:0|1>`: prints the staging root. Mirror: marker, `rsync -a --delete --numeric-ids [--ignore-times] --exclude-from=<list> -- "${BK_INCLUDES[@]}" mirror/`, rsync 24 is a warning, marker removed. Reflink/fresh: new `snap/`.
- `bk_stage_metadata <dest>`: today's `.mc-meta` staging moved into a function.
- `bk_stage_discard_run`: removes `snap/` and `meta/`, never `mirror/`.

`lib/bk_archive.sh`
- `bk_archive_create <stage_root> <meta_root|""> <tier_dir> <stamp> <level> <hourly:0|1>`: prints the `.part` path. `tar -cf - -C stage_root . [-C meta_root .mc-meta] [--exclude=*.jar]` piped to `zstd -T<n> -<level> -o part`; per-stage exit codes from `PIPESTATUS`.
- `bk_archive_verify <file>`: single `zstd -dc | tar -tf -` pass; requires `*/level.dat` and `*/region/*.mca` (or `level.dat` at root for a server whose world is the root); returns 65 on content failure, 1 on stream failure.
- `bk_archive_publish <part> <final>`: writes `.meta/...sha256` via tmp plus `mv`, then `mv -T part final`.
- `bk_archive_link_tiers <final> <tier...>`: `ln`, else `cp --reflink=auto`, else `cp`; sidecar per link.
- `bk_archive_is_valid_quick <file>`: sidecar present and newer than file and file non-empty; else 2 (unknown).

`lib/bk_space.sh`
- `bk_space_needed <mode>`: prints bytes.
- `bk_space_available <dir>`: prints bytes (`df --output=avail -B1`).
- `bk_space_preflight <mode>`: returns 0, or runs `cleanup_backups.sh --make-room <bytes>` and re-checks, or returns 73.

`lib/bk_state.sh`
- `bk_state_write_last <rc> <tier> <file> <bytes> <seconds> <stage>`: atomic JSON write.
- `bk_state_skip_streak inc|reset`: prints the new count.
- `bk_state_attempts <tier> <date> inc|get`.

`lib/bk_schedule.sh`
- `bk_due_tiers <YYYY-MM-DD> <dow 1-7> <dom> <flags_dir> <generations:true|false> <max_attempts>`: prints the due archive tiers, highest first, one per line (empty means hourly). Pure: no clock, no I/O beyond reading flag files, so tests can feed any date.

`common/archive_restore.sh` (existing names kept, new ones added)
- `validate_archive <file>`: kept; becomes one pass.
- `archive_open_trusted <file>`: opens a fd, checks owner and link-count rules on the opened inode, sets `AR_FD`; returns 1 on refusal.
- `extract_archive_fd <fd> <format> <dest>`: extracts from the fd; old `extract_archive <file> <dest>` kept as a wrapper for `rollback.sh` until it is migrated.
- `scan_staged_tree <staging>`: rejects escaping symlinks except legacy jar links.
- `carry_over_live <server> <staging> <names...>`: copies missing entries with `cp -a --reflink=auto`.
- `swap_server_dir <staging> <server> [keep|discard]`: third argument now explicit; restore.sh and rollback.sh pass `keep` unless `--discard-old` or `RESTORE_KEEP_OLD=false`.

### 4.4 Configuration keys

Existing keys keep their meaning: `BACKUPS_PATH`, `COMPRESSION_LEVEL`, `MAX_STORAGE_GB`, `DO_GENERATION_BACKUPS`, `MAX_HOURLY_BACKUPS`, `MAX_DAILY_BACKUPS`, `MAX_WEEKLY_BACKUPS`, `MAX_MONTHLY_BACKUPS`, `MAX_UPDATE_BACKUPS`, `MAX_CUSTOM_BACKUPS`, `SAVE_TIMEOUT_SECONDS`, `BACKUP_UMASK`.

New, all optional:

| Key | Default | Meaning |
|---|---|---|
| `BACKUP_HOURLY_LEVEL` | `COMPRESSION_LEVEL` | zstd level for hourly |
| `BACKUP_ARCHIVE_LEVEL` | `max(COMPRESSION_LEVEL, 15)` | zstd level for archive tiers |
| `BACKUP_ZSTD_THREADS` | `max(1, min(4, nproc/2))` | `0` means all cores |
| `BACKUP_STAGING_MODE` | `auto` | `auto`, `mirror`, `reflink`, `fresh` |
| `BACKUP_FOLLOW_SYMLINKS` | `true` | dereference top-level symlinks |
| `BACKUP_EXTRA_EXCLUDES` | empty | space-separated rsync patterns |
| `BACKUP_SPACE_MARGIN_PCT` | `5` | free-space margin for the preflight |
| `BACKUP_TIMEOUT_MINUTES` | `120` | supervisor timeout per run |
| `BACKUP_SKIP_ALERT_AFTER` | `3` | consecutive 75 exits before a warning |
| `BACKUP_ARCHIVE_MAX_ATTEMPTS` | `3` | failed attempts per tier per day |
| `BACKUP_LOG_MAX_MB` | `10` | rotation threshold for `backup.log` |
| `RESTORE_KEEP_OLD` | `true` | keep `<server>.pre-restore` (D2) |
| `RESTORE_KEEP_OLD_DAYS` | `7` | cleanup expiry for the kept tree |
| `RESTORE_CARRY_OVER` | `logs crash-reports ledger.sqlite` | copied from the live tree into staging (D5) |

New webhook event names: `backup_skipped` (warning). Existing `backup_failed`, `backup_complete`, `storage_warning` are reused.

### 4.5 Exit-code contract

Existing codes keep their meaning so the wrapper and `upgrade-server.js` see nothing new on known paths. New codes are only used for conditions that today exit `1`, and any caller that treats "non-zero other than 75 and 3" as failure keeps working (to verify in the wrapper repo).

| Code | backup.sh | restore.sh / rollback.sh | run_backup.sh | cleanup_backups.sh |
|---|---|---|---|---|
| 0 | success (and `--dry-run`) | success, or user declined at the prompt (unchanged) | backup ok or skipped | done or skipped |
| 1 | any failure, usage error (unchanged) | any failure, untrusted or invalid archive (unchanged) | backup failed | config error in `--make-room` |
| 3 | n/a | server running or state unknown (unchanged) | n/a | n/a |
| 65 | archive verified but content sanity failed | n/a | propagated | n/a |
| 73 | not enough free space after eviction | not enough free space for staging plus kept tree | propagated | `--make-room` could not free enough |
| 75 | lock held, skipped (unchanged) | lock held (unchanged) | never (mapped to 0, unchanged) | never |
| 124 | n/a | n/a | backup timed out (supervisor) | n/a |
| 129/130/143 | HUP/INT/TERM, after full cleanup | same | propagated | n/a |

### 4.6 Logging format

One line per event, all scripts:

```
2026-10-21 14:20:03 [INFO] [backup:hourly] Mirror refreshed: 214 files, 1.3 GiB changed, 8.4 s under save-off
2026-10-21 14:20:41 [SUCCESS] [backup:hourly] Published minecraft_backup_2026-10-21_14-20-00.tar.zst (2.1 GiB, level 3, T4)
2026-10-21 14:20:42 [INFO] [cleanup] Deleting: hourly/minecraft_backup_2026-10-21_11-20-00.tar.zst
```

Component tags: `backup:<tier>`, `run_backup`, `cleanup`, `restore`, `rollback`. Keep existing message wording where tests assert it (`grep` the test files before rewording). Every run logs the save-off duration explicitly; it is the metric this redesign optimizes.

Status file `.meta/last_backup.json` (written atomically):

```json
{"finished":"2026-10-21T14:20:41+02:00","rc":0,"tier":"hourly","tiers":["hourly"],
 "file":"hourly/minecraft_backup_2026-10-21_14-20-00.tar.zst","bytes":2254857830,
 "seconds":41,"save_off_seconds":8.4,"staging":"mirror","level":3,"threads":4,"stage":"done"}
```

`doctor.sh` and the wrapper can read it ("no successful backup in 3 hours") without parsing logs.

### 4.7 Lifecycle sequences

Hourly or archive run:

```
cron :20 -> run_backup.sh
  export PATH; rotate backup.log if > BACKUP_LOG_MAX_MB
  tiers = bk_due_tiers(today, dow, dom, flags, DO_GENERATION_BACKUPS, max_attempts)
  bk_space_preflight(mode) --short--> cleanup_backups.sh --make-room N --still short--> rc 73
  timeout ${BACKUP_TIMEOUT_MINUTES}m backup.sh [--archive <tiers[0]>] (extra tiers passed via env BK_EXTRA_TIERS)
  | backup.sh
  |   bk_load_config; bk_probe_priority
  |   acquire_operation_lock (fd 7) -> flock .backup.lock (fd 9) --busy--> exit 75
  |   remove stale .part and legacy tmp_backup/
  |   send_message "Starting ... backup"
  |   server up? -- yes --> _AUTO_SAVE_DISABLED=true; save-off (strict); save-all flush (confirmed)
  |   bk_stage_refresh(mode, full = archive run)        <-- save-off window is only this step
  |   save-on; _AUTO_SAVE_DISABLED=false; log save_off_seconds
  |   server state changed stopped->running? --> fail (stage=stage)
  |   archive run: bk_stage_metadata
  |   part = bk_archive_create(...)                      niced, capped threads
  |   bk_archive_verify(part)                            one pass + content sanity
  |   bk_archive_publish(part, final); bk_archive_link_tiers(final, extra tiers)
  |   bk_state_write_last; notify_success; wait_for_notifications
  |   EXIT: save-on if needed -> rm .part -> bk_stage_discard_run -> notify on failure -> wait -> unlock
  rc 0  -> touch flags of every built tier; skip_streak reset
  rc 75 -> skip_streak inc; >= BACKUP_SKIP_ALERT_AFTER -> notify_warning backup_skipped (once)
  rc 124/137 -> save-on via RCON if up; notify_error "timed out"; attempts inc
  rc other and archive run -> attempts inc; run backup.sh (hourly) once
  cleanup_backups.sh
  exit rc
```

Restore (CLI or wrapper):

```
restore.sh --file F --y [--archive] [--discard-old]
  argument and terminal checks (unchanged)
  acquire_operation_lock --busy--> 75
  F = resolve_backup_file / selection by filename stamp
  archive_open_trusted(F) -> AR_FD              trust is bound to this inode from here on
  require_server_stopped --running--> 3          early check kept (wrapper contract)
  space check: staging (+ kept tree needs no extra) --short--> 73
  prompt (interactive only)
  trap EXIT: swap_recover; rm staging; release lock (rm .mc-meta only after success)
  extract_archive_fd(AR_FD, staging)             single decompression; failure leaves live tree untouched
  scan_staged_tree(staging) --escape--> 1
  complete_staged_jars(staging, server)          unchanged
  carry_over_live(server, staging, RESTORE_CARRY_OVER)
  root? chown --reference=server staging
  require_server_stopped --running--> 3
  swap_server_dir(staging, server, keep|discard)
  metadata restore (unchanged rules); rm .mc-meta
```

Rollback (D8): same as restore, but `extract`, `scan`, `complete_staged_jars` run before `systemctl stop`; then stop, re-check, carry over, swap, start; on failure start the original.

Cleanup:

```
cleanup_backups.sh [--make-room BYTES]
  acquire_operation_lock --busy--> exit 0 (unchanged)
  validate config (bad tier value: WARN and skip that tier)
  --make-room: evict in tier order until BYTES are free (df), never newest valid per tier; exit 0 or 73
  normal: count caps per tier -> custom caps -> prune_orphan_jars (daily, early-exit) -> pre-restore expiry
          -> storage limit (du excludes .stage, .meta, jars; link-count aware)
  legacy archives without sidecar: niced zstd -t, write "verified-legacy" sidecar (max 2 per run)
```

### 4.8 Migration and compatibility plan

- **Existing archives:** names, formats and tier folders are unchanged; no rewrite. Archives without a sidecar are valid by the old rule (`zstd -t`/`gzip -t`) and get a `verified-legacy` sidecar lazily. Legacy jar-link archives remain restorable (scan allowlist, `complete_staged_jars`).
- **First run after upgrade:** removes `hourly/tmp_backup` and `archives/*/tmp_backup` under the lock; the first mirror refresh is a full copy (same cost as today); later runs are incremental.
- **Flags:** existing `daily_<date>` etc. keep working; new counters are additive files in the same dir.
- **Config:** nothing required; `variables.txt` without new keys behaves as today except the zstd thread cap (D4), the default keep-old restore (D2) and carry-over (D5), all three called out in the CHANGELOG.
- **Wrapper:** argument shapes unchanged. Verify in the wrapper repo that its backup listing filters by `minecraft_backup_*.tar.(zst|gz)` or at least ignores dotfiles; until confirmed, the leading-dot `.part` name and the separate `.meta/` dir are the defence.
- **Rollback path:** `extract_archive <file> <dest>` stays as a wrapper so `rollback.sh` and `instance_ops.sh` keep working before their own migration task.
- **Docs:** update `docs/backup-restore.md` (sections Backup, Cleanup, Restore, Rollback, Tests) and add glossary entries: *staging mirror*, *save-off window*, *sidecar*, *due tier*, *pre-restore copy* (update the existing entry: now default, with expiry), *carry-over*.

### 4.9 Test plan

**Shim fixes (Phase 0, before any behaviour change):**
- `shims/timeout`: today it always exits 124, which would make a supervised `run_backup.sh` untestable. Make it run the command by default (emulate with `"$@"`), and exit 124 only when `TIMEOUT_SHIM_EXPIRE=1`. Set that variable in the tests that need today's behaviour (`test_server_control.sh`, `test_webhook.sh` use it; check each case).
- `shims/rsync`: exec the real rsync when `MC_TEST_REAL_TOOLS=1` and one exists (same pattern as `REAL_TAR`/`REAL_FLOCK`); in cp mode, emulate `--delete` by clearing the destination before copying and honour `--exclude=*.jar` minimally; add `RSYNC_SHIM_EXIT=<n>` (for 24, 11, 23).
- `shims/zstd`: log level and `-T` value; accept `-T<n>`, `-<level>`, `--check`, `-dc` from stdin; add `ZSTD_SHIM_FAIL_DECOMPRESS=1` and `ZSTD_SHIM_ENOSPC=1` (write partial output, exit 1); real zstd under `MC_TEST_REAL_TOOLS=1`.
- New `shims/ionice` (`IONICE_SHIM_FAIL=1` exits 1 without running the command, `-t` honoured) and `shims/df` (`DF_SHIM_AVAIL=<bytes>`).
- `tests/shell/run.sh`: print the number of skipped cases at the end so a green Windows run is not mistaken for full coverage.
- CI (`.github/workflows/tests.yml` already installs rsync and zstd): add a second job step running the backup, restore and cleanup suites with `MC_TEST_REAL_TOOLS=1`.

**New tests (grouped by the task that introduces them):**
- Priority probe: failing `ionice` still runs rsync and tar; only `nice` present; neither present.
- Trap and signals: TERM during rsync and during compression asserts `save-on` sent before staging removal (order in `SHIM_LOG`), `.part` removed, lock free, `backup_failed` webhook, exit 143.
- Failure notifier: rsync failure and a forced `set -e` abort both send exactly one `backup_failed` and reach `wait_for_notifications`.
- Atomic publish: during compression only `.minecraft_backup_*.part` exists; restore selection, cleanup and `upgrade-server.js`'s regex ignore it; stale `.part` is removed by the next run.
- Verify: archive without `level.dat` is rejected with 65; single decompression in backup (count `zstd` invocations in `SHIM_LOG`).
- Schedule table: `bk_due_tiers` for Mon 00:20, Mon 01:20 after a failed 00:20, ordinary Sunday, first Sunday, first Sunday after a failed monthly, attempts exhausted, generations off.
- Supervisor: timeout -> `save-on` sent, webhook, rc 124; three consecutive 75 -> one `backup_skipped`; archive failure -> hourly made in the same run.
- Space: `DF_SHIM_AVAIL` low -> `--make-room` called; still low -> 73 and webhook; eviction ignores hardlinked bytes.
- Mirror: second run copies only changed files (real rsync job); `MIRROR_INCOMPLETE` blocks tar; deleted source file disappears from the mirror; hourly tar excludes jars while the mirror holds them.
- Tier links: first Sunday builds one archive, three tier entries with the same inode, three flags.
- Restore: default keeps `.pre-restore`; `--discard-old` deletes; expiry after 7 days in cleanup; carry-over of logs, crash reports, ledger; failed restore keeps live `.mc-meta`; swapped-file-after-open still restores the opened inode (TOCTOU); escaping symlink rejected, legacy jar link accepted; `--ago` picks by filename stamp and refuses far matches; missing tier dir gives the friendly error.
- Cleanup: empty `jars/` removed and no archive is decompressed (assert no `zstd -d` in `SHIM_LOG`); decimal `MAX_STORAGE_GB` handled; bad tier value skips only that tier; legacy archive gets a sidecar once.
- Root restore ownership: skipped on Windows; on Linux CI with `sudo` available.
- `migrate-lib/backup.sh`: failed tar leaves no archive and is not counted by prune.

### 4.10 Implementation tasks, ordered by dependency

Each task is one engineer pass, lands with its tests, and runs the shell suite once at the end of the task. Tasks in the same phase without a listed dependency can run in parallel.

**Phase 0: test infrastructure**
- **T0.1** Shim fixes (`timeout`, `rsync`, `zstd`, new `ionice`, `df`) and skipped-count summary in `run.sh`. Depends: none.
- **T0.2** CI step with `MC_TEST_REAL_TOOLS=1` for backup, restore, cleanup suites. Depends: T0.1.

**Phase 1: safety fixes on the current structure**
- **T1.1** `lib/bk_common.sh`: `bk_log`, `bk_die`, `bk_load_config` (validation of existing numeric keys, F24), `bk_probe_priority`/`bk_nice` (F13); switch backup.sh and cleanup to it. Depends: T0.1.
- **T1.2** backup.sh trap rework: order, INT/TERM/HUP, `BK_STAGE`, single failure notifier, `wait_for_notifications`, curl fd closing, broadcast after lock and not in dry-run (F05, F12, F20, F23). Depends: T1.1.
- **T1.3** Restore selection fix (filename stamp, maxdepth 1, exact names, missing dir) (F18). Depends: T0.1.
- **T1.4** `.part` publish, sidecar in `.meta/`, single-pass verify with content sanity (F09, F14 backup side). Depends: T1.2, T1.3.
- **T1.5** Restore safety: keep-old default with `--discard-old` and `RESTORE_KEEP_OLD`, carry-over, `.mc-meta` only on success, root `chown`, trash-rename of the old tree (F01, F07, F19, F21, F22). Requires D2 and D5. Depends: T1.3.
- **T1.6** fd-based trusted open, single-pass extract, staged-tree scan, `--ago` distance rule (F11, F14 restore side). Depends: T1.5.
- **T1.7** Cleanup: `prune_orphan_jars` early exit, daily cadence, `rmdir`, streamed listing, niced; per-tier config errors no longer abort; `.pre-restore` expiry (F04, F24). Depends: T1.1, T1.5.

**Phase 2: scheduling and operations**
- **T2.1** `lib/bk_schedule.sh` and `run_backup.sh` rewrite to due-tier logic with attempt caps and hourly fallback (F06). Depends: T1.2.
- **T2.2** Supervisor: `PATH`, `timeout`, `save-on` recovery, skip streak alert, log rotation (F08, F25, F26). Depends: T2.1, T0.1 (timeout shim).
- **T2.3** `lib/bk_state.sh` and `last_backup.json`; `doctor.sh` reads it. Depends: T1.4.
- **T2.4** `lib/bk_space.sh`, preflight in run_backup, `cleanup_backups.sh --make-room` (F10). Depends: T2.3 (size estimate), T1.7.

**Phase 3: performance and storage**
- **T3.1** Level and thread keys (`BACKUP_HOURLY_LEVEL`, `BACKUP_ARCHIVE_LEVEL`, `BACKUP_ZSTD_THREADS`), example and wizard default 3 for new installs, `tools/bench_levels.sh` (F02). Requires D4. Depends: T1.1.
- **T3.2** `lib/bk_stage.sh`: mirror, reflink, fresh, `auto` probe, `MIRROR_INCOMPLETE`, `--ignore-times` on archive runs, stopped-to-running re-check, drop `sleep 2` and `--inplace`, `du` excludes `.stage` (F03). Requires D3. Depends: T1.4, T2.4.
- **T3.3** One archive per due set with hardlinks into tier dirs; link-count aware eviction (R-P5, F06 second half). Depends: T2.1, T3.2.
- **T3.4** Sidecar-based `protected_archive`, lazy `verified-legacy` migration (F14 cleanup side). Depends: T1.4, T1.7.
- **T3.5** Top-level symlink follow, rsync 24 as warning, `BACKUP_EXTRA_EXCLUDES`, `./`-prefixed includes, wire or drop `--verbose` (F15, F16, F17, F25, F30). Depends: T3.2.

**Phase 4: follow-ups**
- **T4.1** Rollback prepares staging before stopping (D8), using the Phase 1 restore helpers. Depends: T1.6.
- **T4.2** `migrate-lib/backup.sh`: `.part`, `tar -t` verify, rename, prune ignores `.part` (F29). Depends: none.
- **T4.3** Docs and glossary update for everything above, including the stale lines (F31) and a CHANGELOG entry listing the three default behaviour changes. Depends: all shipped tasks.
- **T4.4** Optional `<server>.restoring` start guard in `start.sh` (F28). Depends: T1.5.
- **T4.5** Optional, only if D1 becomes (b): post-publish export hook (`BACKUP_POST_PUBLISH_CMD`) receiving the final path, run niced after the lock is released. Depends: T1.4.
