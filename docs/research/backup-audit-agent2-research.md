# Backup audit: Bash and ecosystem research (Agent 2)

Scope: external research to inform an audit of `src/scripts/backup/` (tar-style archives, RCON save-off/save-all, retention cleanup, cron/systemd). The repo was only skimmed: `backup.sh` already has an EXIT trap, a `nice_run` helper (ionice -c2 -n7 + nice 10), a TMP_DIR/PARTIAL_ARCHIVE cleanup path and an operation lock, but runs with `set -e` only.

Evidence labels: **[src]** = number or statement taken from a fetched page (URL given). **[kb]** = general knowledge not verified in this session; verify before relying on it. Nothing here was benchmarked locally.

---

## 1. Robust Bash for heavy I/O automation

### 1.1 Strict mode caveats
- `set -e` is unreliable by design. The Wooledge BashFAQ/105 maintainers recommend explicit error checks over relying on it. Documented traps [src: https://mywiki.wooledge.org/BashFAQ/105]:
  - `test -d x && echo y` does not exit on failure (conditional context).
  - `let i++` with i=0 returns status 1 and kills the script.
  - `local var=$(failing_cmd)` discards the exit status (declare then assign on separate lines).
- `set -e` is also suppressed inside `if`, `while`, left of `&&`/`||`, and inside any function called from such a context. A cleanup or verify function called as `if ! verify; then` will silently continue after an inner failure.
- `pipefail` is required for `tar | zstd > out`; without it only the last stage status counts. With it, inspect `"${PIPESTATUS[@]}"` immediately after the pipeline (any intervening command resets it) to know which stage failed. `tar` exit 1 ("file changed as we read it") is a warning, 2 is fatal; map them explicitly [kb].
- `set -u` breaks on empty arrays in Bash < 4.4 (`"${arr[@]}"`); use `${arr[@]+"${arr[@]}"}` if old Bash matters. Git Bash and modern Linux ship 4.4+/5.x [kb].
- Recommended baseline: `set -Eeuo pipefail`, `IFS=$'\n\t'` optional, plus explicit `|| die` on every step whose failure must be handled differently (RCON, archive, verify, rename).
- ERR trap needs `-E` (errtrace) to fire in functions and subshells [kb].

### 1.2 Trap and cleanup
- One EXIT trap that is idempotent and owns all cleanup (temp dir, partial archive, lock, `save-on`) is the accepted pattern [src: https://mundobytes.com/scripting-en-bash-con-set-euo-pipefail-trap-y-logging/ and other roundups]. The repo already does this.
- Add `trap 'exit 130' INT` and `trap 'exit 143' TERM` so signals route through the EXIT trap (bash runs EXIT on signal-induced exit only if the signal trap calls `exit`; default SIGTERM death skips some cleanup paths) [kb]. Critical for systemd stop and cron kill.
- SIGKILL cannot be trapped: a crash between `save-off` and `save-on` leaves autosave disabled. Mitigation: always send `save-on` at the start of the next run (idempotent; failure "already enabled" is harmless per the Minecraft wiki) and alert if `save-off` is found active.
- Do not rely on the trap alone for the `save-on` path when the server may be restarted by another process; check state, do not assume.

### 1.3 Locking
- `flock` on a held file descriptor is the standard: `exec 9>"$LOCK"; flock -n 9 || exit 0` [src: https://man7.org/linux/man-pages/man1/flock.1.html]. Options: `-n` nonblocking, `-w sec` timeout, `-E code` conflict exit code (use a distinct code so cron/systemd can tell "skipped, already running" from failure).
- The lock is released when the fd closes; children inherit the fd. A backgrounded child (e.g., a long `rclone`) that outlives the script keeps the lock; use `flock -o` or close the fd (`9>&-`) in spawned daemons [src: flock(1), -o/-F].
- NFS/CIFS: flock has limited or failing semantics there [src: flock(1)]. Keep the lock file on local disk (`/run/lock` or the server dir), never on the backup share.
- Windows/Git Bash and BSD/macOS: `flock` is not available in the util-linux form. Portable fallback is `mkdir "$LOCK.d"` (atomic) plus a PID file with stale-lock detection (`kill -0`) [src: https://flutter.googlesource.com/mirrors/flutter/+/5267d9877248f2531e5e6e4a1619eded8b6ae0ce%5E%21/ shows exactly this fallback chain]. Since the project is Linux-first, prefer flock with a mkdir fallback.
- systemd alternative: a `.service` is already single-instance per unit (a timer will not start a second run while it is active). cron needs flock.

### 1.4 Atomic writes
- Pattern: write to `name.tmp.$$` in the **same filesystem and directory**, `sync` the file (or `fsync` via `dd conv=fsync` / `sync -f file` on coreutils 8.24+), `mv -T tmp final` (rename is atomic on POSIX), then `sync` the directory [kb]. Never produce a final-named file before it is complete; retention and restore must ignore `*.tmp`/`*.partial`.
- Write the checksum manifest (`sha256sum` or `b3sum`) after the archive is renamed or as part of the same atomic step, and make it a sidecar `.sha256` written tmp+rename so a manifest never describes a half archive.
- Verify before publishing: `zstd -t`/`gzip -t`/`tar -tf >/dev/null` on the temp file, then rename. Catches truncated output from a full disk, which a `set -e` pipeline without pipefail would miss.
- Check free space up front (`df --output=avail`), because ENOSPC mid-compress is the most common backup failure on game hosts.

### 1.5 Resource limits
- `nice -n 10 ionice -c2 -n7` (what the repo does) is correct for CFQ/BFQ; on `mq-deadline`/`none` schedulers (default on NVMe) ionice is mostly ignored [kb]. For a real cap use systemd resource control in the unit: `Nice=`, `IOSchedulingClass=`, `CPUQuota=`, `IOWeight=`, `MemoryMax=`, or `systemd-run --scope -p CPUQuota=50%` from cron [kb].
- Limit compressor threads explicitly: `zstd -T2`, `pigz -p 2`, so the compressor does not steal all cores from the game server tick thread. `-T0` uses all physical cores [src: zstd manpage, https://manpages.debian.org/testing/zstd/zstd.1.en.html].
- `--adapt` in zstd adjusts the level to I/O back-pressure, useful when piping to a slow remote [src: zstd manpage].

### 1.6 Pipes, process substitution, misc
- Prefer streaming pipelines (`tar -C ... -cf - . | zstd -T2 -3 > tmp`) over staging a full copy in TMP_DIR. The repo stages a tree first (TMP_DIR); this doubles I/O and disk use but gives a consistent copy point so save-on can be sent sooner. That tradeoff is real: staging with `cp --reflink=auto` on btrfs/XFS is near free [kb].
- Process substitution `<(...)` is Bash-only, not available in `sh`/dash and its failure status is lost under `set -e`; use only where needed, and capture `$!`/`wait` if the status matters.
- `shellcheck` catches quoting, unchecked `cd`, `local x=$(...)` masking (SC2155), `read` without `-r`, and unreachable-`set -e` patterns. Run it in CI with `-x` (follow sources) and `--severity=style`; enforce on the `common/` sourced files too. bats-core (TAP-compliant) runs under `errexit`, so test functions must not rely on non-zero returns without `run` [src: bats search results, https://pypi.org/project/batspp/2.1.4 and bats-core mirrors]. Use `bats-assert`/`bats-support`, stub `rcon-cli`/`tar` by prepending a fake `bin/` to PATH, and test the trap path by sending TERM to a child.
- Portability: GNU vs BSD differ on `stat -c` vs `stat -f`, `date -d`, `tar` output format and `sed -i` [src: https://tech.yahoo.com/computing/articles/beware-6-inconsistent-linux-commands-120017711.html and Git tar portability commit]. Git Bash (MSYS) lacks flock, has slow fork, no real symlinks without privilege, `/proc`, ionice or cgroups. Treat Windows as "runs unit tests and dry-run only"; keep backup execution Linux-first and isolate non-portable calls in `common/utils.sh` wrappers (`file_mtime`, `file_size`, `acquire_lock`, `nice_run`). Note the global instruction says everything must work on both OSes, so wrappers plus `command -v` capability checks are the right shape.

---

## 2. How existing tools handle Minecraft backups

### 2.1 Consistency and atomicity (applies to every tool)
- `save-all` (normal) only **marks** chunks dirty; they are written over time. `save-all flush` writes everything immediately and freezes the server briefly. `save-off` stops writing level files and queues changes; `save-on` resumes; each errors if already in that state [src: https://minecraft.wiki/w/Commands/save-all].
- Therefore the correct, documented sequence is `save-off` -> `save-all flush` -> (wait for the "Saved the game" reply) -> `sync` -> copy -> `save-on`. Plain `save-all` followed immediately by copy can capture half-written regions; PaperMC staff confirm chunk IO is asynchronous so even `save-all` returns before the data is fully on disk [src: https://forums.papermc.io/threads/does-save-all-obey-max-auto-save-chunks-per-tick/]. The audit should check the repo uses `flush` and waits for the response, not a fixed sleep.
- itzg/docker-mc-backup sequence: save-off, save-all, (optional `sync` via `ENABLE_SYNC`), backup, save-on [src: https://github.com/itzg/docker-mc-backup/wiki]. It uses `ENABLE_SAVE_ALL=true` and `ENABLE_SYNC=true` by default semantics; a gap vs flush is worth noting [kb: newer versions send `save-all flush`; verify].
- Even with save-off, player data, advancements and stats are still written (wiki quote above), so playerdata consistency is weaker than region consistency. Acceptable, but document it.
- Copy-on-write snapshots (ZFS, btrfs, LVM) shrink the save-off window from minutes to milliseconds: freeze with save-off/flush, snapshot, immediately save-on, then back up the snapshot at leisure [src: https://rubenerd.com/replacing-a-bunch-of-tarballs-with-zfs-snapshots and the Minecraft "Snapshot" ZFS plugin listing]. A crash-consistent snapshot without save-off is usually loadable but can lose recent chunks [kb].

### 2.2 Tool-by-tool

| Tool | Method | Consistency handling | Dedup / incremental | Retention | Verification | Offsite | Fit for pure-Bash, low-dependency |
|---|---|---|---|---|---|---|---|
| **tar + zstd/gzip (current)** | Full archive each run | Needs script-driven save-off/flush | None; N full copies | Script (count/age) | `tar -t`, sidecar checksum if added | rclone/rsync of files | Native, but storage grows linearly |
| **itzg/docker-mc-backup** | `BACKUP_METHOD` tar, rsync, restic, rclone | save-off, save-all, optional sync, save-on via RCON | tar none; rsync incremental; restic CDC dedup | `PRUNE_BACKUPS_DAYS`, `PRUNE_BACKUPS_COUNT`, `PRUNE_RESTIC_RETENTION` (e.g. `--keep-within 7d`) | restic check manual | rclone method, restic remotes, `RESTIC_LIMIT_UPLOAD` | Good reference for design; Docker-centric. [src: github.com/itzg/docker-mc-backup/wiki] |
| **rsync `--link-dest`** | Dated dirs, unchanged files hardlinked | Same RCON dance | File-level only. A region file with one changed chunk is stored whole again (typically 1 to 32 MB) | rm -rf old dirs (GFS by script) | `rsync -c` / `--checksum` dry run | rsync over ssh | Excellent: coreutils-level, no new deps, browsable |
| **BorgBackup** | CDC chunks (buzhash), repo | Same | Block dedup, defaults: min 512 KiB, max 8 MiB, mask 21 bits (~2 MiB target) [src: https://borgbackup.readthedocs.io/en/stable/internals/data-structures.html]; `fixed` chunker available, with header and sparse support | `borg prune --keep-*` | `borg check` (`--verify-data`) | Needs borg on remote or via rclone of repo | Strong, but new dependency, locks repo |
| **restic** | CDC chunks, packs | Same | Block dedup; zstd compression by default since 0.14 [src: servercrate.net/restic-vs-borg] | `forget --keep-last/hourly/daily/weekly/monthly/yearly/within`, ORed together, grouped by host+paths, then `prune` (default `--max-unused 5%`) [src: https://restic.readthedocs.io/en/stable/060_forget.html] | `check`, `--read-data`, `--read-data-subset n/t, x%, nS` [src: https://restic.readthedocs.io/en/stable/045_working_with_repos.html] | Native S3/B2/SFTP/rclone backends | Best single-binary option if one dependency is acceptable |
| **kopia** | CDC, repo, policies | Same | Block dedup; fastest in one benchmark | Policy-based | `kopia snapshot verify` | Native cloud | Heavier, server/UI optional |
| **ZFS/btrfs/LVM snapshots** | CoW | Snapshot in ms after save-off/flush | Block-level CoW, near-free incrementals via `send`/`receive` | Snapshot destroy scripts | `zfs scrub`, `btrfs scrub` | send/receive | Filesystem dependent; huge win where available |
| **rdiff-backup (minebackup.sh)** | Reverse-incremental diffs | Screen-session pause | Binary delta per file | Quota in MiB | rdiff-backup verify | n/a | Python dep, niche [src: https://github.com/axipher/minebackup.sh] |
| **Prime Backup (MCDR plugin)** | Content-addressed hash pool | Plugin-driven | File-level plus optional fixed/CDC chunking for large files, compression, validation | PBS-style pruning, cron schedule | Integrity validation and compaction | Not built in | Design reference [src: https://mcdreforged.com/plugin/prime_backup] |
| **Backuper / FTB Backups / Simple Backups / Fast Async Backups (mods)** | Zip or snapshot of world in-process | Mod pauses saving internally (save-off/save-all/save-on equivalent) | Mostly full zips; some incremental | Count or size limits | Rarely | Rarely | In-process mods; not directly comparable [src: search results, e.g. https://www.curseforge.com/minecraft/mc-mods/fast-async-backups] |

Backup-tool performance reference (Linux kernel sources and qcow2, not Minecraft) [src: https://github.com/deajan/backup-bench]:
- Local kernel tree, 1st / 2nd / restore: Borg 41 s / 22 s / 16 s; restic 23 s / 8 s / 9 s; Kopia 10 s / 4 s / 5 s.
- Remote qcow2 initial: Borg 7,044 s (123.1 GB repo), restic 8,848 s (116.2 GB), Kopia 12,125 s (140.0 GB).
- Other claims: borg compression is 5 to 15% better on text-heavy data, restic wins repo checks over SFTP [src: servercrate.net/restic-vs-borg, marketing-grade, low confidence].

### 2.3 Dedup on `.mca` region files: what is actually known
- Region format [src: minecraft.fandom.com region format, plus WorldRegionOptimizer listing https://hangar.papermc.io/PlanetDogeCodes/WorldRegionOptimizer]: up to 1024 chunks per file, each chunk zlib-compressed independently at **level 1**, stored in 4 KiB sectors, with a header table of offsets and timestamps. Repacking at deflate level 9 reportedly shrinks regions 40 to 60%.
- Consequences (reasoning, [kb], no published dedup benchmark for .mca was found in this session):
  1. Outer compression (gzip/zstd) of regions yields little, because data is already deflate output, but level-1 deflate leaves some redundancy; expect single-digit to low-tens of percent gain, higher for zstd than gzip. Measure on a real world.
  2. Each chunk is compressed independently and rewritten in place only when modified. Unmodified chunks are byte-identical across backups, so CDC dedup (borg, restic, kopia) works at roughly "changed chunks only", but a rewritten chunk that grows can move to a new sector run and shift everything after it. CDC (2 MiB target in borg) copes with shifts; fixed-size chunking at 4 KiB multiples is also plausible because sectors are 4 KiB aligned, but a smaller chunk size means more index metadata.
  3. Dedup across backups wins most when many regions are untouched (large, mostly explored but idle worlds); it loses on actively-edited areas because the header timestamp table changes every save.
  4. rsync `--link-dest` gets zero benefit within a changed region file (whole file stored again); it only saves untouched files. For a world of 1 to 32 MB regions, with players active across many regions per hour, the saving is mostly cold regions.
  5. A real data point for dedup in general: a community post cites 81 GB source -> 28 GB for four backups (borg with compression and dedup) vs a 662 GB single-backup run for restic [src: https://dev.to/ahferroin7/comment/n21h]; this comment's dataset is not Minecraft and the restic figure looks inconsistent, so treat as anecdote only.
- Recommendation: measure on your own world with `borg create --stats` / `restic backup --verbose` over 3 to 4 consecutive hourly runs before committing; cheap to do.

### 2.4 Retention (GFS)
- restic semantics: keep-* options OR together; e.g. `--keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 6` gives a GFS ladder. Snapshots are grouped by host and paths, so a changed path accidentally creates a separate group [src: restic forget docs].
- Implementing GFS in pure Bash: bucket archive timestamps with `date +%Y%m%d%H`, `%G-W%V`, `%Y%m` (GNU date; ISO week uses `%G-%V` not `%Y-%U`), keep the newest per bucket for each tier, delete the rest. The union rule means a file is deleted only if no tier wants it. Always run with a dry-run mode, always keep at least N newest, and never delete when the newest backup failed verification (otherwise retention can delete the last good backup).
- Guard: refuse to prune if the listing is empty, the clock is wrong (timestamp in future), or the backup dir is not mounted.

### 2.5 Offsite
- rclone: `rclone copy`/`sync` of finished archives or restic repo; use `--checksum`, `--immutable` (never overwrite changed remote file), `--transfers`, `--bwlimit`; for `sync` add `--max-delete` and `--backup-dir` to avoid a local mistake wiping the remote [kb]. Upload from the finished atomic file only (never `.tmp`). itzg rclone method uploads compressed files; restic exposes `RESTIC_LIMIT_UPLOAD` [src: itzg wiki].
- Verify after upload with `rclone check` (size+hash where supported) or `rclone cryptcheck`.

---

## 3. Benchmarks

No Minecraft-specific compression benchmark with published numbers was found. The data below is from a generic disk image; the structure (deflate-compressed chunk blobs) makes Minecraft behave like "mostly incompressible, modestly compressible", so use the *relative* speed ordering, not the ratio, and verify with your own world.

Generic reference: 4.0 GB Ubuntu disk image, Ryzen 9 5900X, 64 GB RAM, NVMe [src: https://redpill-linpro.com/techblog/2024/12/18/compression-tool-test.html]. Ratio = compressed/original (lower is smaller).

| Tool, setting | Ratio | Compress | Decompress | Threads |
|---|---|---|---|---|
| gzip default | 12.4% | 0:50 | 0:17 | 1 |
| gzip -9 | 12.4% | 2:49 | 0:17 | 1 |
| pigz default | 12.4% | 0:06 | 0:08 | multi |
| pigz -9 | 12.4% | 0:12 | 0:08 | multi |
| zstd default (-3) | 10.2% | 0:05 | 0:03 | 1 |
| zstd -T0 default | 10.2% | 0:01 | n/a | multi |
| zstd --ultra -22 -T0 | 7.6% | 3:45 | 0:03 | multi |
| xz default | 7.4% | 4:31 | 0:18 | 1 |
| xz -T0 | 7.5% | 0:25 | n/a | multi |
| xz -9e -T0 | 7.2% | 1:34 | 0:18 | multi |
| bzip2 -9 | 11.0% | 1:28 | 0:36 | 1 |

Other quoted figures [src: search snippets, https://www.cnx-software.com/2016/12/19/facebook-zstandard-zstd-pzstd-data-compression-tools-deliver-high-performance-efficiency/ and others]: pigz 143 MB/s ratio 3.06 vs zstd level 3 at 122 MB/s ratio 3.17; zstd levels 3 to 6 are the usual sweet spot [lower confidence, secondary summaries].

Takeaways for this project:
- zstd -3 single-thread already beats gzip default on both speed and ratio, and decompresses ~5x faster than gzip; multi-threaded it is ~5x faster again. It is the clear default; keep `.tar.gz` read support for old archives.
- pigz matches gzip format (readable anywhere), so it is the right fallback when zstd is not installed. Same ratio as gzip, much faster.
- xz only pays off for cold/offsite archives where time is irrelevant; never on an hourly job (4:31 default single thread).
- `-T0` takes all physical cores [src: zstd manpage]; on a game host cap it (`-T2`) or the server tick suffers.
- `--long[=27]` enlarges the match window (128 MiB default 27) and helps when similar data sits far apart, e.g., many near-duplicate region files in one tar [src: zstd manpage]; costs memory on decompress too (needs `--long=27` or `--memory`). Likely small win for already-deflated chunks; test.
- `--rsyncable` (zstd, and `pigz --rsyncable`) makes consecutive archives rsync/rclone-delta-friendly at negligible ratio cost, but reduces speed with threads [src: zstd manpage]. Only relevant if offsite uses rsync delta; irrelevant for rclone which does whole-file transfer.
- Default zstd level is 3; levels above 19 need `--ultra` and much more memory [src: zstd manpage]. Use `-T`, `-c`, `--check` (default on) for integrity.
- Dedup savings for borg/restic on `.mca`: no published number found (see 2.3). Backup-bench numbers above are for kernel source and qcow2 only.

---

## 4. Restore best practices

Applied to this project (Bash, tar-style archives):

1. **Verify before touching anything**: check the sidecar checksum (`sha256sum -c`), then `zstd -t`/`gzip -t`, then `tar -tf archive >/dev/null`, and check that the member list has the expected root (`level.dat`, `region/`), is not absolute-path or contains `..` (tar path traversal), and that unpacked size fits free disk space.
2. **Restore into a temp directory on the same filesystem** as the live world, then validate (level.dat exists and is readable, region dir non-empty, optionally `nbt` parse or a headless server dry start) and **swap with rename**: `mv world world.pre-restore.TS && mv restore.tmp world`. Two renames on the same filesystem are near-atomic and fast to roll back. Do not extract over the live directory.
3. **Pre-restore safety snapshot**: always take a fresh backup (or at least the rename-kept `world.pre-restore.TS`) before replacing. Keep it outside retention's reach for a grace period, because retention that prunes the pre-restore copy defeats it.
4. **Stop the server** (or at least `save-off` + `save-all flush` and kick players) before swap; a running server will overwrite the restored files on next save. Restart after swap and confirm startup via log line, with auto rollback on failure if feasible.
5. **Checksum manifest**: per archive `name.sha256` written atomically; for staged trees optionally a manifest of per-file hashes so partial restores can be verified. restic offers `check --read-data-subset` for sampled integrity audits; a Bash analogue is a periodic job that verifies a random 1 to 5 backups end to end (decompress + tar -t + hash) [src: restic docs for the pattern].
6. **Periodic restore drills**: the strongest verification is an actual restore to a scratch dir and a server boot. Schedule monthly and record the result (the Minecraft community warning that a corrupt region file "will not be found until restore day" captures the risk; src: https://dev.to/ahferroin7/comment/n21h search snippet).
7. Restore must be **idempotent and resumable**: if it fails mid-way, the original is still there (guaranteed by steps 2 and 3).
8. Provide `--dry-run` that prints what would be replaced and which backup would be used (selection by timestamp, with "latest verified good" rather than "latest file").

---

## 5. Ranked patterns worth adopting (pure Bash, dependency-light, Linux-first)

Ranked by risk reduction per unit of effort. "Impact" is for data safety unless noted.

1. **Atomic publish plus completion verification** (tmp name, `pipefail` + `PIPESTATUS`, `zstd -t`/`tar -tf`, sha256 sidecar, `mv -T`, ignore `*.partial` everywhere). Eliminates truncated/corrupt archives being treated as good and then rotating out the last good one. Low effort.
2. **Correct Minecraft quiesce sequence**: `save-off`, `save-all flush`, wait for the confirmation line (not a sleep), `sync`, copy/stage, `save-on`; idempotent `save-on` at both start and exit; EXIT + INT/TERM traps. Low effort; verify against current code.
3. **Retention that cannot delete the last good backup**: prune only after the new backup passed verification, GFS buckets (hourly/daily/weekly/monthly) with a dry-run flag, guards for empty listing/unmounted dir/future clock, `-E`-distinct exit codes. Low to medium effort.
4. **flock single-instance lock** (fd-based, `-n`, distinct `-E` code, local filesystem) with `mkdir` fallback for non-Linux. Low effort. Mostly present in repo as an "operation lock"; audit its semantics (stale lock, fd inheritance by long-running children).
5. **Switch default compressor to zstd with `-T` capped (e.g., 2) and `nice`/`ionice`, fallback pigz, then gzip**, record the compressor in the filename so restore auto-detects. Measured ordering: zstd -3 beats gzip on speed and ratio [src: redpill-linpro]. Low effort.
6. **Restore safety**: verify first, extract to temp on same filesystem, rename swap, keep `world.pre-restore.TS`, require server stopped. Low to medium effort.
7. **systemd unit hardening** for scheduling: `Type=oneshot`, `Nice=`, `IOSchedulingClass=`, `CPUQuota=`, `MemoryMax=`, `TimeoutStartSec=`, `OnFailure=` notification, `Persistent=true` timer. Gives real resource caps that `ionice` cannot on NVMe. Low to medium effort.
8. **Offsite with rclone** (`copy --immutable --checksum`, then `rclone check`), uploading only completed files, bandwidth limit, never `sync` without `--max-delete`. Medium effort, optional dependency.
9. **Test and lint gates**: shellcheck in CI (including sourced `common/*`), bats-core with a fake-PATH stub harness for `rcon`, `tar`, `zstd`, tests for trap/cleanup, retention maths, and restore rollback. Medium effort, big long-term safety.
10. **Optional content-addressed layer** only if storage is the pain point: either rsync `--link-dest` (no new deps; savings only for cold regions) or restic/borg (block dedup; one new dependency, best long-term storage). Defer until the storage growth is measured on the real world; keep the tar path as the zero-dependency default.
11. **Periodic restore drill and sampled integrity audit** (monthly full restore into scratch, daily hash re-check of a random subset). Medium effort.
12. **Filesystem snapshots (ZFS/btrfs/LVM) as an optional fast path** when detected, shrinking the save-off window to milliseconds; skip on ext4. Medium effort, host dependent.

### Things to avoid
- Relying on `set -e` alone for correctness (BashFAQ/105).
- `-T0` on the game host (starves the tick thread).
- xz or `zstd --ultra` on an hourly timer.
- Plain `save-all` without `flush` followed by an immediate copy.
- `flock` on NFS/CIFS; lock files on the backup share.
- Pruning before the new backup is verified.
- Extracting a restore over the live world directory.

## 6. Source list
- https://mywiki.wooledge.org/BashFAQ/105
- https://man7.org/linux/man-pages/man1/flock.1.html
- https://manpages.debian.org/testing/zstd/zstd.1.en.html
- https://redpill-linpro.com/techblog/2024/12/18/compression-tool-test.html
- https://github.com/deajan/backup-bench
- https://github.com/itzg/docker-mc-backup/wiki
- https://restic.readthedocs.io/en/stable/060_forget.html
- https://restic.readthedocs.io/en/stable/045_working_with_repos.html
- https://borgbackup.readthedocs.io/en/stable/internals/data-structures.html
- https://minecraft.wiki/w/Commands/save-all
- https://forums.papermc.io/threads/does-save-all-obey-max-auto-save-chunks-per-tick/
- https://mcdreforged.com/plugin/prime_backup
- https://github.com/axipher/minebackup.sh
- https://rubenerd.com/replacing-a-bunch-of-tarballs-with-zfs-snapshots
- https://hangar.papermc.io/PlanetDogeCodes/WorldRegionOptimizer
- https://servercrate.net/restic-vs-borg/
- https://dev.to/ahferroin7/comment/n21h
- https://flutter.googlesource.com/mirrors/flutter/+/5267d9877248f2531e5e6e4a1619eded8b6ae0ce%5E%21/
- https://www.cnx-software.com/2016/12/19/facebook-zstandard-zstd-pzstd-data-compression-tools-deliver-high-performance-efficiency/

## 7. Gaps and caveats
- No Minecraft-specific compression ratio or dedup benchmark with numbers was found; section 2.3 reasoning is inference. Recommend a 30-minute local experiment: take 4 hourly copies of a real world, compare tar+gzip, tar+zstd -3, rsync --link-dest, borg and restic sizes.
- Items tagged [kb] (ionice behavior on NVMe, PIPESTATUS mapping of tar exit codes, rclone flags, `save-all flush` in recent itzg versions, `sync -f`) were not verified in this session.
- The repo was only skimmed (head of `backup.sh`, no deep read), so statements about current behavior are limited to what the first 60 lines show.
