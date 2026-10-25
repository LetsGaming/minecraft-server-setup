# Creative mirror server: technical blueprint

> **Status (2026-10-26):** the mirror described here is implemented; use [docs/mirror.md](../mirror.md) and `src/mirror/`. The script templates in this document were found to need fixes when they were run (see [2026-10-25-creative-mirror-vm-test-audit.md](2026-10-25-creative-mirror-vm-test-audit.md)); do not copy them.

Status: research and design, not implemented in this repo. Date: 2026-10-24.
Companion document: [creative-mirror-sync-audit.md](creative-mirror-sync-audit.md) (findings, risks, sources, open verification items).

Goal: a dedicated `creative-server-vm` runs one Fabric 26.3 instance that holds

1. a mirror of the survival Overworld (same seed, same terrain and builds, refreshed every 24 hours from `survival-server-vm` on another host), and
2. an independent flat plot world that the refresh never touches,

while the live survival server never gets corrupted, locked indefinitely or slowed down by the transfer.

## 0. Design in one page

```
 survival-server-vm (host A)                          creative-server-vm (host B)
 ┌───────────────────────────────────────┐            ┌──────────────────────────────────────────┐
 │ survival.service (screen + Fabric)    │            │ creative.service (screen + Fabric)       │
 │  world/dimensions/minecraft/overworld │            │  world/dimensions/minecraft/overworld  ◄─┼── swapped nightly
 │                                       │            │  world/dimensions/fabricplots/plots      │   (never touched)
 │ 04:40 mc-mirror-export.timer          │            │ 05:15 mc-mirror-pull.timer               │
 │  1. save-off + save-all flush         │            │  1. fetch LATEST manifest                │
 │     (or reuse the backup staging copy)│   rsync    │  2. delta-pull snapshot -> pull cache    │
 │  2. local copy -> snapshots/<stamp>   │◄───ssh─────┤  3. pre-stage copy next to the world     │
 │  3. save-on                           │  read-only │  4. stop server, rename swap, start      │
 │  4. publish LATEST manifest           │  rrsync key│  5. health check, rollback on failure    │
 │ ~mcsync: rrsync -ro on export root    │            │ key: ~/.ssh/mc_mirror_ed25519            │
 └───────────────────────────────────────┘            └──────────────────────────────────────────┘
                     ▲                                                  ▲
                     └──────────── itzg/mc-router (edge) ───────────────┘
                     survival.example.net               creative.example.net
```

Key decisions (reasons in the audit):

| Decision | Choice | Why |
|---|---|---|
| Where the mirror lives | The creative server's own `minecraft:overworld`, created with the survival seed | No 26.3 world manager can reload a dimension from disk at runtime, so any mirror needs a stop anyway. Using the main overworld keeps villager memories, lodestones and portals pointing at the right dimension and needs no extra mod. |
| Plot world | FabricPlots 1.0.2+26.3 (`fabricplots:plots` dimension) | Only 26.3 mod with a real plot grid and `/plot claim`; it ships its own flat dimension, so no world manager is needed. |
| Direction | Creative **pulls** with a read-only key | A compromised creative VM can only read the export tree. Survival holds no credentials for creative. |
| Consistency | Transfer from an immutable local snapshot, never from the live world | The network transfer can be slow or fail; the live server is only in `save-off` for a local copy (or not at all in `stage` mode). |
| Cross-host coordination | None. Two independent timers plus a manifest | Survival never waits for creative; creative refuses stale or already-applied snapshots. |
| Creative downtime | Seconds (rename swap of pre-staged folders) | The copy into place happens while the creative server is still running. |
| Scheduler | systemd timers (as requested). This repo uses cron today; see the audit (R-03). | |

## 1. Recommended mod stack (Fabric 26.3)

All builds verified on Modrinth/GitHub on 2026-10-24. Java 25 is required by Minecraft 26.3.

### 1.1 Creative server

| Component | Version (26.3) | Side | License | Role |
|---|---|---|---|---|
| Minecraft server | 26.3 (DataVersion 5023, released 2026-09-15) | | | Same version as survival (hard requirement, audit F-06) |
| Fabric Loader | 0.20.1 (2026-10-19) | server | Apache-2.0 | |
| Fabric API | 0.165.0+26.3 (2026-10-23) | server | Apache-2.0 | |
| **FabricPlots** (`fabricplots`) | 1.0.2+26.3 (2026-09-24) | server only | MIT | Flat plot dimension `fabricplots:plots`, `/plot claim/auto/home/visit/menu`, merging, per-plot biome. Bundles sgui. |
| **Dimensional Inventories** (`dimensional-inventories`) | 2.2.2+26.3 (2026-09-16) | server only | MIT | Separate inventory, ender chest, XP and gamemode per dimension pool (mirror pool vs plot pool) |
| **LuckPerms** | v5.5.85-fabric (2026-09-19) | server only | MIT | Permissions for `/plot`, `/diminv`, staff |
| Leukocyte (`leukocyte`) | 0.4.1+26.3 (2026-10-10) | server only | LGPL-3.0 | Optional: make the mirror dimension read-only (`/protect add mirror with minecraft:overworld`, deny `break`/`place`/`interact_blocks`) |
| Panda Per-World-Seed (`pandaperworldseed`) | 1.2.0+26.3 (2026-10-04) | server only | CC0 | Optional fallback only: if the creative world already exists with a different seed, pin `minecraft:overworld` to the survival seed in `config/per_world_seed.json` |
| FabricProxy-Lite | not verified for 26.3 | server only | | Only if mc-router sends PROXY protocol (section 7) |

Vanilla clients can join: every mod above is server-side.

Configuration essentials:

```properties
# server.properties on creative (before the very first start)
level-name=world
level-seed=<survival seed, from /seed on survival>
level-type=minecraft\:normal
gamemode=creative
force-gamemode=false
region-file-compression=deflate
enable-rcon=false
```

```properties
# config/fabricplots.properties
# Dimensional Inventories owns gamemode switching; two mods fighting over it
# causes gamemode flapping on dimension change.
manage-gamemode=false
```

```text
# one-time, from the console (permission level 4)
/diminv pool plots create
/diminv pool plots dimension fabricplots:plots assign
/diminv pool plots gamemode creative
/diminv pool mirror create
/diminv pool mirror dimension minecraft:overworld assign
/diminv pool mirror gamemode creative      # or adventure/spectator for a look-only mirror
```

Players reach the plot world with `/plot world` (FabricPlots) or `/execute in fabricplots:plots run tp @s 0 65 0`. Everything built in the mirror is discarded at the next refresh; tell players so in the MOTD or a join message, or lock the mirror with Leukocyte.

### 1.2 Survival server

No extra mod. The export uses vanilla `save-off`, `save-all flush`, `save-on` through `screen` (this repo's default) or RCON.

### 1.3 Alternatives considered (details in audit section 3)

| Candidate | 26.3 status | Verdict |
|---|---|---|
| Worlds: Multiverse for Fabric (`mc-worlds`) 1.10.0+26.3 | available | Fallback A: mirror as a separate dimension (`/worlds create mirror <seed>`), auto-unloads when empty. Young project. No reload-from-disk. |
| World Manager (`melius-worldmanager`) 1.5.1+26.3 | available | Fallback A': can import a world folder (`/wm create <id> <path>`), Fantasy-based. |
| Multiworld (`multiworld`) 1.14.2 | beta | `/mw create <id> NORMAL -g=FLAT -s=<seed>`; load/unload "coming soon". |
| Multiverse (`multiverse-dimensions`) 0.6.0+26.3 | available | Has `clone`, but warns it can hang the server. |
| RegionCast (`regioncast`) 1.0.2+26.3 | available | Purpose-built mirror tool, but needs filesystem access to both worlds and documents only vanilla dimension ids; 83 downloads. Interesting, not production-ready for cross-host use. |
| Dimenager, DimensionsCore, PlotSquared for Fabric | do not exist on Modrinth | Not usable. |
| Vanilla datapack dimensions | built in | Fallback B for the plot world without a plot grid: `data/<ns>/dimension/<name>.json` with `minecraft:flat`. Note the 26.x `dimension_type` format change: reference `minecraft:overworld`. |

## 2. Directory layout blueprint

Minecraft 26.1 moved every dimension under `dimensions/` (snapshot 26.1-snap6); 26.2 and 26.3 kept that layout. Any guide that says `world/region` or `world/DIM-1` is pre-26.1 and wrong for this setup.

### 2.1 creative-server-vm

Paths follow this repo's layout (`$HOME/<TARGET_DIR_NAME>/instances/<instance>`); adapt if yours differ.

```
/home/mc/minecraft-server/
├── instances/creative/                      SERVER_DIR (creative.service WorkingDirectory)
│   ├── server.properties                    level-name=world, level-seed=<survival seed>
│   ├── mods/                                fabric-api, fabricplots, dimensional-inventories, luckperms, ...
│   ├── config/fabricplots.properties
│   ├── logs/latest.log                      read by the pull script (start detection, version)
│   └── world/                               never synced as a whole
│       ├── level.dat                        creative's own: NEVER synced
│       ├── session.lock
│       ├── data/minecraft/                  creative's own (scoreboard, maps, game_rules, world_gen_settings): NEVER synced
│       ├── players/{data,stats,advancements}/   creative's own: NEVER synced
│       ├── datapacks/
│       └── dimensions/
│           ├── minecraft/
│           │   ├── overworld/               MIRRORED DIMENSION
│           │   │   ├── region/r.X.Z.mca     replaced nightly
│           │   │   ├── entities/r.X.Z.mca   replaced nightly
│           │   │   ├── poi/r.X.Z.mca        replaced nightly
│           │   │   └── data/minecraft/      creative's own (raids, chunk_tickets, world_border): kept
│           │   ├── the_nether/              creative's own unless added to MIRROR_DIMS
│           │   └── the_end/                 creative's own unless added to MIRROR_DIMS
│           └── fabricplots/
│               └── plots/                   PLOT DIMENSION: never touched by the sync
│                   ├── region/  entities/  poi/  data/
└── mirror-sync/                             SYNC_ROOT: outside SERVER_DIR, same filesystem
    ├── .pull.lock                           flock, one pull at a time
    ├── LATEST.remote                        last fetched manifest
    ├── APPLIED                              snapshot id currently live
    ├── cache/                               PULL CACHE: persistent delta target
    │   ├── MANIFEST                         manifest of the cached snapshot
    │   ├── .INCOMPLETE                      present while a pull is unfinished
    │   └── minecraft/overworld/{region,entities,poi}/
    ├── incoming/minecraft/overworld/...     pre-staged copy, renamed into the world at swap time
    ├── rollback/minecraft/overworld/...     previous live folders, kept until the next run
    ├── failed/<stamp>/...                   snapshots that failed the start check (kept 7 days)
    ├── SWAP_IN_PROGRESS                     swap journal (exists only mid-swap)
    └── STOPPED_BY_SYNC                      server was stopped by the sync and not yet restarted
```

Why `mirror-sync/` sits outside `SERVER_DIR`: this repo's backup stages and archives the whole server directory, so a cache inside it would double every creative backup. It must be on the same filesystem as the world so the swap is a `rename(2)`; the script refuses to run otherwise.

Steady-state disk use on creative is about 3x the mirrored dimension size (cache + live + rollback), and the same 3x at peak because the previous rollback is deleted before `incoming/` is built. On btrfs or XFS with reflink, `cp --reflink=auto` makes `incoming/` nearly free.

### 2.2 survival-server-vm

```
/home/mc/minecraft-server/
├── instances/survival/                      SERVER_DIR (live, only read during the save-off window)
│   └── world/dimensions/minecraft/overworld/{region,entities,poi}/
├── backups/survival/                        this repo's BACKUPS_PATH
│   ├── .backup.lock                         taken by the export (SHARED_LOCKS) so it never overlaps a backup
│   ├── .stage/mirror/world/dimensions/...   backup staging mirror (source in SOURCE_MODE=stage)
│   └── .meta/last_backup.json
└── mirror-export/                           EXPORT_ROOT, mode 2750, group mcsync
    ├── .export.lock
    ├── .save-off-active                     exists only inside the save-off window
    ├── LATEST                               manifest of the newest snapshot (atomic rename)
    └── snapshots/
        ├── 20261023T024000Z/                previous (kept so a running pull never loses its files)
        └── 20261024T024000Z/                EXPORT SNAPSHOT (immutable once published)
            ├── MANIFEST
            └── minecraft/overworld/{region,entities,poi}/r.X.Z.mca
```

Snapshots are built with `rsync --link-dest=<previous snapshot>`, so unchanged region files are hard links and each snapshot costs only the changed files. Region files written by Minecraft change in place, but the snapshot's inodes belong to the export tree, not the live world, so the live server never writes into a snapshot.

### 2.3 Manifest format

Plain `key=value`, parsed with `awk`, never `source`d:

```
format=1
snapshot=20261024T024000Z
created_epoch=1792809600
source_mode=live
mc_version=26.3
level_seed=-4172144997902289642
dims=minecraft/overworld
files=1834
bytes=12884901888
```

## 3. Step-by-step remote sync workflow

### 3.1 Nightly timeline

| Time (local) | Host | Step | Live survival impact |
|---|---|---|---|
| hh:20 every hour | survival | This repo's hourly backup (cron) refreshes `.stage/mirror` | Existing save-off window |
| 04:40 | survival | `mc-mirror-export.service` | `live` mode: one short save-off window (flush + local delta copy). `stage` mode: none. |
| 05:15 (+0-5 min random) | creative | `mc-mirror-pull.service` | Only disk/network reads of the snapshot, at `nice 19` / `ionice idle` (rrsync forced command) and `--bwlimit` |

### 3.2 Export (survival VM, runs as the survival server user)

1. **Locks.** `flock` on `EXPORT_ROOT/.export.lock`, then every file in `SHARED_LOCKS` (recommended: the repo's `$BACKUPS_PATH/.backup.lock` and the instance operation lock), waiting up to `LOCK_WAIT` seconds. This serializes the export with backups and restores, which also toggle `save-off`.
2. **Preflight.** Validate `MIRROR_DIMS` against an allowlist (`minecraft/overworld|the_nether|the_end`), read `level-name`, require the 26.x `dimensions/` layout, check free space on `EXPORT_ROOT` (last snapshot size or `du` of the source, plus margin).
3. **Pre-flush** (`SOURCE_MODE=live`, server running):
   - create `.save-off-active` marker, send `save-off`;
   - send `save-all flush`; wait for `]: Saved the game` in `logs/latest.log` after the recorded byte offset (screen mode; the regex is anchored so chat cannot spoof it), or for the RCON reply;
   - `save-all flush` briefly blocks the server thread in proportion to dirty chunks; that is the only TPS cost, and it is the same one every backup already pays.
4. **Local snapshot.** For each mirrored dimension and each of `region entities poi`: `rsync -rt --link-dest=<previous> --include='r.*.*.mca' --exclude='*'` into `snapshots/.incoming.<stamp>/`, under `nice 10` / `ionice -c2 -n7`, wrapped in `timeout SAVE_OFF_MAX`. Local rsync copies whole files and uses temp-file-plus-rename, so a half-copied file never appears under its final name.
5. **save-on** immediately after the copy. The EXIT trap sends it on any failure; if the process is killed with SIGKILL, `ExecStopPost=... --ensure-save-on` sends it from systemd. Saving can never stay off longer than the job.
   - `SOURCE_MODE=stage` skips steps 3 and 5 entirely: it copies from the backup staging mirror (which the backup already flushed) while holding the backup lock, refusing if `MIRROR_INCOMPLETE` exists or the mirror is older than `STAGE_MAX_AGE_MIN`. Requires `BACKUP_STAGING_MODE=mirror` in this repo (the `auto` default prefers reflink and keeps no persistent mirror).
6. **Manifest and publish.** Count region files and bytes, record `mc_version` (from `Starting minecraft server version` in the log) and the configured seed, `mv -T` the incoming directory to `snapshots/<stamp>`, then atomically replace `LATEST`.
7. **Prune** to `KEEP_SNAPSHOTS` (minimum 2, so a pull that started on the previous snapshot keeps its files).

### 3.3 Transport (creative VM pulls)

- SSH: ed25519 key, `BatchMode=yes`, `StrictHostKeyChecking=yes` against a pinned `known_hosts` file, `IdentitiesOnly=yes`, `ConnectTimeout=15`, `ServerAliveInterval=15`, `ServerAliveCountMax=4`.
- Survival side: the key is only accepted from the creative VM's address and is forced into `rrsync -ro <EXPORT_ROOT>`, so it can read the export tree and nothing else (no shell, no forwarding, no writes, no access to `variables.txt` or the live world).
- rsync flags: `-rt` (not `-a`: owner/group/devices are meaningless here, and rrsync 3.5 disables device handling), `--delete-delay`, `--partial-dir=.rsync-partial` (resumable, never a partial file under a live name), `--timeout=600`, `--bwlimit`. No `-z` (chunks are already zlib/lz4 compressed), no `--checksum` (reads every byte on both sides), no `--inplace` (unsafe for interrupted transfers).
- Root-anchored filters: only `region/`, `entities/`, `poi/` and `r.*.*.mca` inside them can reach the cache.
- Retries: exit codes 10, 12, 30, 35 and 255 (socket, protocol, timeout, ssh failure) are retried `RETRIES` times with `RETRY_DELAY`; anything else fails fast. A failed pull leaves `.INCOMPLETE` in the cache and never touches the creative server; the next night resumes from the partial cache.

### 3.4 Path target isolation

Isolation is enforced in four independent places, so one mistake cannot reach the plot world:

1. Export allowlist: only `minecraft/overworld|the_nether|the_end` may be exported.
2. Export content: snapshots contain only `region/entities/poi` region files; no `level.dat`, `data/`, `players/`.
3. Pull filters: anchored includes accept nothing else, whatever the server sends.
4. Swap scope: the swap renames exactly `world/dimensions/<dim>/{region,entities,poi}` for each allowlisted `<dim>`. `world/dimensions/fabricplots/plots`, `world/level.dat`, `world/data/`, `world/players/` and `world/dimensions/<dim>/data/` are never opened.

### 3.5 Service reload (creative VM)

1. Fetch `LATEST`, refuse if the id is malformed, older than `MAX_SNAPSHOT_AGE_H`, missing a configured dimension, already in `APPLIED` (exit 0, no restart), or built by a different Minecraft version than the creative server runs (`REQUIRE_SAME_VERSION=1`).
2. Space check after dropping the previous rollback.
3. Delta-pull into `cache/`, verify file count and byte total against the manifest (rsync already verifies every transferred file with a whole-file checksum).
4. Take `SHARED_LOCKS` on creative (its backup/operation lock), then copy `cache/` to `incoming/` while the server still runs.
5. Warn players (`say` at `WARN_SECONDS` and 10 s), write `STOPPED_BY_SYNC`, `sudo -n systemctl stop creative.service` (the repo's unit runs `graceful_stop.sh`, which saves), wait until both the unit and the screen session are gone.
6. Swap: write `SWAP_IN_PROGRESS`, `mv -T` live folders to `rollback/`, `mv -T` pre-staged folders in, remove the journal. A few renames, so downtime is the stop plus the start.
7. Start, wait for `]: Done (Ns)!` in a fresh `latest.log` (the script follows log rotation by inode). On success write `APPLIED`.
8. On start failure: stop, move the rejected folders to `failed/<stamp>/`, rename `rollback/` back, start again, report. If the script is killed mid-swap, `ExecStopPost=... --recover` replays the journal and restarts the server.
9. If the creative server was already stopped (maintenance), the swap happens but the server is left stopped.

## 4. SSH authentication setup (ed25519)

Accounts:

- survival VM: `mc` runs the server and the export; `mcsync` is a separate, shell-less account that only serves `rrsync -ro`. Keeping the read-only account separate means a compromise of the key (or an rrsync escape, see audit F-03) cannot read `variables.txt`, RCON passwords or the live world.
- creative VM: `mc` runs the server and the pull, and owns the private key.

### 4.1 survival-server-vm (as root)

```bash
apt-get install -y rsync            # provides /usr/bin/rrsync
# trixie: install rsync >= 3.5.0 from trixie-security (CVE-2026-53783, audit F-03)
apt-cache policy rsync

adduser --system --group --home /home/mcsync --shell /bin/sh mcsync
# mc must be in group mcsync, or Linux silently drops the setgid bit when the
# export script (running as mc) creates or chmods directories in the export tree
usermod -aG mcsync mc
install -d -o mc -g mcsync -m 2750 /home/mc/minecraft-server/mirror-export
# mcsync must be able to traverse to EXPORT_ROOT; grant only search (x) permission
setfacl -m u:mcsync:x /home/mc /home/mc/minecraft-server   # or chmod o+x if ACLs are unavailable

install -d -o root -g root -m 755 /home/mcsync/.ssh
cat >/home/mcsync/.ssh/authorized_keys <<'EOF'
restrict,from="203.0.113.20",command="nice -n 19 ionice -c3 /usr/bin/rrsync -ro /home/mc/minecraft-server/mirror-export" ssh-ed25519 AAAA...REPLACE... mc-mirror@creative
EOF
chown root:root /home/mcsync/.ssh/authorized_keys
chmod 644 /home/mcsync/.ssh/authorized_keys
```

- `restrict` disables PTY, agent/X11/port forwarding and `~/.ssh/rc`; `command=` ignores whatever the client asks to run; `from=` pins the creative VM's address (use its WireGuard address if you tunnel, audit F-10).
- `authorized_keys` is root-owned, so even a shell escape could not add keys.
- `/bin/sh` (dash) as login shell: rrsync's man page warns that bash may read rc files before the forced command.
- `nice`/`ionice` go into `command=` because a forced command ignores the client's `--rsync-path`.
- Optional sshd hardening in `/etc/ssh/sshd_config.d/mcsync.conf`:

  ```
  Match User mcsync
      AuthenticationMethods publickey
      PasswordAuthentication no
      AllowTcpForwarding no
      X11Forwarding no
      PermitTTY no
  ```

### 4.2 creative-server-vm (as mc)

```bash
ssh-keygen -t ed25519 -a 100 -N '' -C mc-mirror@creative -f ~/.ssh/mc_mirror_ed25519
cat ~/.ssh/mc_mirror_ed25519.pub        # paste into the survival authorized_keys line above

# pin the survival host key; compare the fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run ON survival
ssh-keyscan -t ed25519 -p 22 survival.example.net > ~/.ssh/known_hosts_mc_mirror
ssh-keygen -lf ~/.ssh/known_hosts_mc_mirror
chmod 600 ~/.ssh/mc_mirror_ed25519 ~/.ssh/known_hosts_mc_mirror

# test: lists the export root through rrsync, nothing else works
rsync -e "ssh -i ~/.ssh/mc_mirror_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts_mc_mirror -o StrictHostKeyChecking=yes" \
  mcsync@survival.example.net:
ssh -i ~/.ssh/mc_mirror_ed25519 mcsync@survival.example.net id   # must be refused by rrsync
```

The key has no passphrase because a timer uses it unattended; the `restrict,from=,command=rrsync -ro` line is what limits it. If you prefer a passphrase, load it into an agent at boot with `systemd-creds`; that adds moving parts for little gain here.

### 4.3 sudo on creative

The pull script stops and starts the creative unit with `sudo -n systemctl stop|start creative.service`. This repo already installs exactly that rule (`docs/sudoers-setup.md`); without the repo:

```
# /etc/sudoers.d/mc-mirror (visudo -f)
mc ALL=(root) NOPASSWD: /usr/bin/systemctl start creative.service, /usr/bin/systemctl stop creative.service
```

## 5. Ready-to-use script templates

Both scripts are self-contained Bash (Debian 12/13: bash 5, coreutils, util-linux `flock`/`ionice`, rsync, screen; jq and curl only for the optional webhook). They log to stdout, which systemd sends to journald under the unit's `SyslogIdentifier`. Exit codes follow sysexits: 0 ok, 65 stale/invalid snapshot, 69 source unavailable, 73 no space, 75 lock busy (retry later), 78 config error, 1 operational failure.

Both are lint-clean under ShellCheck 0.11 (`-S style`, with this repo's `.shellcheckrc` exclusions) and pass `bash -n`. They have not been run against real servers; run the verification checklist in the audit (section 6) before relying on them.

### 5.1 `/etc/mc-mirror/export.conf` (survival VM)

```bash
# Sourced by mc-mirror-export.sh. Owned by root, mode 640, group mc.
SERVER_DIR=/home/mc/minecraft-server/instances/survival
EXPORT_ROOT=/home/mc/minecraft-server/mirror-export

# live: own save-off window. stage: copy this repo's backup staging mirror
# (needs BACKUP_STAGING_MODE=mirror), no extra save-off at all.
SOURCE_MODE=live
STAGE_DIR=/home/mc/minecraft-server/backups/survival/.stage/mirror
STAGE_INCOMPLETE_MARKER=/home/mc/minecraft-server/backups/survival/.stage/MIRROR_INCOMPLETE
STAGE_STAMP_FILE=/home/mc/minecraft-server/backups/survival/.meta/last_backup.json
STAGE_MAX_AGE_MIN=90

# Serialize with this repo's backup and restore jobs (both toggle save-off).
SHARED_LOCKS="/home/mc/minecraft-server/backups/survival/.backup.lock /home/mc/minecraft-server/scripts/survival/.locks/operation_survival.lock"
LOCK_WAIT=1800

SCREEN_SESSION=survival
# RCON instead of screen (keep RCON bound to localhost):
# RCON_CMD="mcrcon -H 127.0.0.1 -P 25575"
# export MCRCON_PASS='...'

MIRROR_DIMS="minecraft/overworld"
SAVE_TIMEOUT=120
SAVE_OFF_MAX=600
KEEP_SNAPSHOTS=2
SPACE_MARGIN_MB=2048
LEVEL_SEED=-4172144997902289642
WEBHOOK_URL=
```

### 5.2 `/usr/local/bin/mc-mirror-export.sh` (survival VM)

```bash
#!/usr/bin/env bash
# mc-mirror-export.sh: runs on survival-server-vm as the survival server user.
# Publishes an immutable snapshot of the mirrored dimensions' chunk folders
# under $EXPORT_ROOT/snapshots/<stamp>/ plus $EXPORT_ROOT/LATEST (a manifest).
# The creative VM pulls it read-only through rrsync; nothing here talks to it.
#
# Usage: mc-mirror-export.sh [--config FILE] [--ensure-save-on]
#   --ensure-save-on  only re-enable saving if a previous run died inside the
#                     save-off window (wired to ExecStopPost=).
set -Eeuo pipefail
umask 027

EX_LOCKED=75
EX_NOSPACE=73
EX_UNAVAILABLE=69
EX_CONFIG=78

CONFIG=/etc/mc-mirror/export.conf
MODE="export"
while (($#)); do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --ensure-save-on) MODE=ensure-save-on; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}"; }
die()  { local rc=$1; shift; log ERROR "$*"; FAIL_REASON="$*"; exit "$rc"; }

[[ -r "$CONFIG" ]] || { log ERROR "config not readable: $CONFIG"; exit "$EX_CONFIG"; }
# shellcheck source=/dev/null
source "$CONFIG"

: "${SERVER_DIR:?SERVER_DIR is required}"
: "${EXPORT_ROOT:?EXPORT_ROOT is required}"
SOURCE_MODE="${SOURCE_MODE:-live}"
SCREEN_SESSION="${SCREEN_SESSION:-survival}"
RCON_CMD="${RCON_CMD:-}"
MIRROR_DIMS="${MIRROR_DIMS:-minecraft/overworld}"
CHUNK_DIRS="region entities poi"
SAVE_TIMEOUT="${SAVE_TIMEOUT:-120}"
SAVE_OFF_MAX="${SAVE_OFF_MAX:-600}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-2}"
SPACE_MARGIN_MB="${SPACE_MARGIN_MB:-2048}"
LOCK_WAIT="${LOCK_WAIT:-1800}"
SHARED_LOCKS="${SHARED_LOCKS:-}"
STAGE_DIR="${STAGE_DIR:-}"
STAGE_INCOMPLETE_MARKER="${STAGE_INCOMPLETE_MARKER:-}"
STAGE_MAX_AGE_MIN="${STAGE_MAX_AGE_MIN:-90}"
STAGE_STAMP_FILE="${STAGE_STAMP_FILE:-}"
LEVEL_SEED="${LEVEL_SEED:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

SNAP_DIR="$EXPORT_ROOT/snapshots"
SAVE_OFF_MARKER="$EXPORT_ROOT/.save-off-active"
LOG_FILE="$SERVER_DIR/logs/latest.log"
SAVE_OFF=0
TMP_SNAP=""
FAIL_REASON=""

level_name() {
  local name
  name="$(sed -n 's/^level-name=//p' "$SERVER_DIR/server.properties" 2>/dev/null | tail -n1 | tr -d '\r')"
  name="${name:-world}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != ".." ]] || die "$EX_CONFIG" "unsupported level-name: $name"
  printf '%s\n' "$name"
}

notify() {
  [[ -n "$WEBHOOK_URL" ]] || return 0
  if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
    log WARN "jq or curl missing, webhook skipped"
    return 0
  fi
  local body
  body="$(jq -nc --arg c "[mc-mirror-export] $1" '{content: $c}')"
  # The URL travels on stdin so it never shows up in the process list.
  printf 'url = "%s"\n' "$WEBHOOK_URL" |
    curl --config - -fsS -m 10 -H 'Content-Type: application/json' -d "$body" -o /dev/null ||
    log WARN "webhook delivery failed"
}

validate_dims() {
  local dim
  for dim in $MIRROR_DIMS; do
    [[ "$dim" =~ ^minecraft/(overworld|the_nether|the_end)$ ]] ||
      die "$EX_CONFIG" "MIRROR_DIMS may only list minecraft/overworld, minecraft/the_nether, minecraft/the_end (got $dim)"
  done
}

screen_running() {
  screen -ls 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+\.${SCREEN_SESSION}[[:space:]]"
}

server_running() {
  if [[ -n "$RCON_CMD" ]]; then
    $RCON_CMD list >/dev/null 2>&1
  else
    screen_running
  fi
}

# Prints the command's RCON reply (RCON mode) or nothing (screen mode).
mc_cmd() {
  if [[ -n "$RCON_CMD" ]]; then
    $RCON_CMD "$1"
  else
    screen -S "$SCREEN_SESSION" -p 0 -X stuff "$1"$'\r'
  fi
}

log_size()  { stat -c %s "$LOG_FILE" 2>/dev/null || echo 0; }
log_inode() { stat -c %i "$LOG_FILE" 2>/dev/null || echo 0; }

# wait_log REGEX OFFSET INODE TIMEOUT: true once REGEX appears in latest.log
# after byte OFFSET. A new inode means the log was rotated, so start from 0.
wait_log() {
  local re=$1 off=$2 ino=$3 timeout=$4 i
  for ((i = 0; i < timeout; i++)); do
    if [[ "$(log_inode)" != "$ino" ]]; then ino="$(log_inode)"; off=0; fi
    if tail -c +"$((off + 1))" "$LOG_FILE" 2>/dev/null | grep -qE "$re"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

save_off_and_flush() {
  local off ino reply
  off="$(log_size)"; ino="$(log_inode)"
  # Marker first: if we die between here and save-on, ExecStopPost repairs it.
  : >"$SAVE_OFF_MARKER"
  SAVE_OFF=1
  mc_cmd "save-off" >/dev/null
  reply="$(mc_cmd "save-all flush")"
  if [[ -n "$RCON_CMD" ]]; then
    [[ "$reply" == *"Saved the game"* ]] || die 1 "save-all flush not confirmed over RCON: ${reply:-<empty>}"
  else
    # Anchored so a player typing the phrase in chat cannot fake completion.
    wait_log '\]: Saved the game[[:space:]]*$' "$off" "$ino" "$SAVE_TIMEOUT" ||
      die 1 "save-all flush not confirmed within ${SAVE_TIMEOUT}s"
  fi
}

save_on() {
  ((SAVE_OFF)) || return 0
  if mc_cmd "save-on" >/dev/null; then
    rm -f "$SAVE_OFF_MARKER"
    SAVE_OFF=0
    log INFO "saving re-enabled"
  else
    log ERROR "could not send save-on; run it manually"
  fi
}

on_exit() {
  local rc=$?
  save_on
  [[ -n "$TMP_SNAP" && -d "$TMP_SNAP" ]] && rm -rf -- "$TMP_SNAP"
  if ((rc != 0 && rc != EX_LOCKED)); then
    notify "export FAILED (rc=$rc): ${FAIL_REASON:-see journal}"
  fi
  exit "$rc"
}

hold_lock() {
  local file=$1 fd
  exec {fd}>>"$file"
  flock -w "$LOCK_WAIT" "$fd" || die "$EX_LOCKED" "lock busy after ${LOCK_WAIT}s: $file"
}

latest_snapshot() {
  local f
  f="$(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}T[0-9]{6}Z' -printf '%f\n' 2>/dev/null | sort | tail -n1)"
  [[ -n "$f" ]] && printf '%s\n' "$SNAP_DIR/$f"
  return 0
}

manifest_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null; }

space_preflight() {
  local world=$1 prev=$2 need avail est dim size
  est=0
  if [[ -n "$prev" && -r "$prev/MANIFEST" ]]; then
    est="$(manifest_get bytes "$prev/MANIFEST")"
  fi
  if [[ -z "$est" || "$est" == 0 ]]; then
    est=0
    for dim in $MIRROR_DIMS; do
      size="$(du -sb "$world/dimensions/$dim" 2>/dev/null | cut -f1)" || size=0
      est=$((est + ${size:-0}))
    done
  fi
  need=$((est + SPACE_MARGIN_MB * 1024 * 1024))
  avail="$(df -PB1 --output=avail "$EXPORT_ROOT" | tail -n1 | tr -d ' ')"
  ((avail >= need)) || die "$EX_NOSPACE" "need ~$((need / 1048576)) MiB on $EXPORT_ROOT, have $((avail / 1048576)) MiB"
}

copy_dims() {
  local world=$1 prev=$2 dim d rc link
  for dim in $MIRROR_DIMS; do
    for d in $CHUNK_DIRS; do
      if [[ ! -d "$world/dimensions/$dim/$d" ]]; then
        log WARN "missing $world/dimensions/$dim/$d, skipped"
        continue
      fi
      mkdir -p "$TMP_SNAP/$dim/$d"
      link=()
      [[ -n "$prev" && -d "$prev/$dim/$d" ]] && link=("--link-dest=$prev/$dim/$d")
      rc=0
      timeout "$SAVE_OFF_MAX" nice -n 10 ionice -c2 -n7 \
        rsync -rt --chmod=D2750,F640 "${link[@]}" \
        --include='r.*.*.mca' --exclude='*' \
        -- "$world/dimensions/$dim/$d/" "$TMP_SNAP/$dim/$d/" || rc=$?
      case $rc in
        0) ;;
        24) log WARN "rsync: files vanished in $dim/$d (rc=24), continuing" ;;
        124) die 1 "copy of $dim/$d exceeded SAVE_OFF_MAX=${SAVE_OFF_MAX}s" ;;
        *) die 1 "rsync failed for $dim/$d (rc=$rc)" ;;
      esac
    done
  done
}

write_manifest() {
  local stamp=$1 files bytes version
  files="$(find "$TMP_SNAP" -type f -name 'r.*.*.mca' | wc -l)"
  bytes="$(find "$TMP_SNAP" -type f -name 'r.*.*.mca' -printf '%s\n' | awk '{s += $1} END {print s + 0}')"
  version="$(grep -oE 'Starting minecraft server version [^ ]+' "$LOG_FILE" 2>/dev/null | tail -n1 | awk '{print $NF}')"
  {
    echo "format=1"
    echo "snapshot=$stamp"
    echo "created_epoch=$(date +%s)"
    echo "source_mode=$SOURCE_MODE"
    echo "mc_version=${version:-unknown}"
    echo "level_seed=${LEVEL_SEED:-unknown}"
    echo "dims=$MIRROR_DIMS"
    echo "files=$files"
    echo "bytes=$bytes"
  } >"$TMP_SNAP/MANIFEST"
  log INFO "snapshot $stamp: $files region files, $((bytes / 1048576)) MiB, mc ${version:-unknown}"
}

publish() {
  local stamp=$1 tmp
  mv -T -- "$TMP_SNAP" "$SNAP_DIR/$stamp"
  TMP_SNAP=""
  tmp="$EXPORT_ROOT/.LATEST.$$"
  cp -- "$SNAP_DIR/$stamp/MANIFEST" "$tmp"
  chmod 640 "$tmp"
  mv -f -- "$tmp" "$EXPORT_ROOT/LATEST"
}

prune() {
  local keep=$1 old
  find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}T[0-9]{6}Z' -printf '%f\n' | sort | head -n "-$keep" |
    while IFS= read -r old; do
      log INFO "pruning snapshot $old"
      rm -rf -- "${SNAP_DIR:?}/$old"
    done
}

ensure_save_on() {
  [[ -e "$SAVE_OFF_MARKER" ]] || exit 0
  if ! server_running; then
    # save-off does not survive a restart, so a stopped server needs nothing.
    rm -f "$SAVE_OFF_MARKER"
    exit 0
  fi
  log WARN "previous export died inside the save-off window, re-enabling saving"
  SAVE_OFF=1
  save_on
  ((SAVE_OFF == 0)) || exit 1
  notify "recovered: saving re-enabled after an interrupted export"
  exit 0
}

main() {
  [[ "$SCREEN_SESSION" =~ ^[A-Za-z0-9_-]+$ ]] || die "$EX_CONFIG" "SCREEN_SESSION must match [A-Za-z0-9_-]+"
  if [[ "$MODE" == ensure-save-on ]]; then ensure_save_on; fi

  validate_dims
  if [[ ! "$KEEP_SNAPSHOTS" =~ ^[0-9]+$ ]] || ((KEEP_SNAPSHOTS < 2)); then
    die "$EX_CONFIG" "KEEP_SNAPSHOTS must be >= 2 so a pull in progress never loses its snapshot"
  fi
  mkdir -p "$SNAP_DIR"
  chmod 2750 "$EXPORT_ROOT" "$SNAP_DIR"

  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  hold_lock "$EXPORT_ROOT/.export.lock"
  local lock
  for lock in $SHARED_LOCKS; do hold_lock "$lock"; done

  local level world prev stamp
  level="$(level_name)"
  prev="$(latest_snapshot)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  TMP_SNAP="$SNAP_DIR/.incoming.$stamp"
  rm -rf -- "$SNAP_DIR"/.incoming.*

  case "$SOURCE_MODE" in
    stage)
      [[ -n "$STAGE_DIR" ]] || die "$EX_CONFIG" "SOURCE_MODE=stage needs STAGE_DIR"
      world="$STAGE_DIR/$level"
      [[ -d "$world/dimensions" ]] || die "$EX_UNAVAILABLE" "no staged world at $world (is the backup staging mode 'mirror'?)"
      if [[ -n "$STAGE_INCOMPLETE_MARKER" && -e "$STAGE_INCOMPLETE_MARKER" ]]; then
        die "$EX_UNAVAILABLE" "staging copy is marked incomplete: $STAGE_INCOMPLETE_MARKER"
      fi
      if [[ -n "$STAGE_STAMP_FILE" ]] && [[ -z "$(find "$STAGE_STAMP_FILE" -mmin "-$STAGE_MAX_AGE_MIN" 2>/dev/null)" ]]; then
        die "$EX_UNAVAILABLE" "staging copy older than ${STAGE_MAX_AGE_MIN} min ($STAGE_STAMP_FILE)"
      fi
      space_preflight "$world" "$prev"
      copy_dims "$world" "$prev"
      ;;
    live)
      world="$SERVER_DIR/$level"
      [[ -d "$world/dimensions" ]] || die "$EX_UNAVAILABLE" "no 26.x world layout at $world/dimensions"
      space_preflight "$world" "$prev"
      if server_running; then
        log INFO "server running: save-off + save-all flush"
        local t0=$SECONDS
        save_off_and_flush
        copy_dims "$world" "$prev"
        save_on
        log INFO "save-off window: $((SECONDS - t0))s"
      else
        log INFO "server stopped: copying without a save window"
        copy_dims "$world" "$prev"
      fi
      ;;
    *) die "$EX_CONFIG" "SOURCE_MODE must be live or stage" ;;
  esac

  write_manifest "$stamp"
  publish "$stamp"
  prune "$KEEP_SNAPSHOTS"
  log SUCCESS "published snapshot $stamp"
}

main "$@"
```

### 5.3 `/etc/mc-mirror/pull.conf` (creative VM)

```bash
# Sourced by mc-mirror-pull.sh. Owned by root, mode 640, group mc.
REMOTE=mcsync@survival.example.net
SSH_PORT=22
SSH_KEY=/home/mc/.ssh/mc_mirror_ed25519
KNOWN_HOSTS=/home/mc/.ssh/known_hosts_mc_mirror

SERVER_DIR=/home/mc/minecraft-server/instances/creative
SYNC_ROOT=/home/mc/minecraft-server/mirror-sync
MIRROR_DIMS="minecraft/overworld"

SERVICE=creative.service
SCREEN_SESSION=creative
# STOP_CMD="sudo -n systemctl stop creative.service"
# START_CMD="sudo -n systemctl start creative.service"

# Do not swap while a creative backup or restore runs.
SHARED_LOCKS="/home/mc/minecraft-server/backups/creative/.backup.lock /home/mc/minecraft-server/scripts/creative/.locks/operation_creative.lock"
LOCK_WAIT=1800

BWLIMIT=40000            # KiB/s; 0 = unlimited
RSYNC_TIMEOUT=600
RETRIES=3
RETRY_DELAY=120
MAX_SNAPSHOT_AGE_H=30
REQUIRE_SAME_VERSION=1
WARN_SECONDS=60
STOP_TIMEOUT=360
START_TIMEOUT=300
SPACE_MARGIN_MB=4096
WEBHOOK_URL=
```

### 5.4 `/usr/local/bin/mc-mirror-pull.sh` (creative VM)

```bash
#!/usr/bin/env bash
# mc-mirror-pull.sh: runs on creative-server-vm as the creative server user.
# Pulls the newest survival snapshot over rsync+SSH (read-only rrsync key)
# into a local pull cache, pre-stages a copy next to the world, then stops the
# creative server, swaps only the mirrored dimensions' chunk folders, and
# starts it again. The plot dimension, level.dat, data/ and players/ are never
# touched.
#
# Usage: mc-mirror-pull.sh [--config FILE] [--recover] [--force]
#   --recover  repair an interrupted swap and restart the server if this script
#              stopped it (wired to ExecStopPost=).
#   --force    apply the snapshot even if it was already applied.
set -Eeuo pipefail
umask 027

EX_LOCKED=75
EX_NOSPACE=73
EX_UNAVAILABLE=69
EX_CONFIG=78
EX_STALE=65

CONFIG=/etc/mc-mirror/pull.conf
MODE="pull"
FORCE=0
while (($#)); do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --recover) MODE=recover; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}"; }
die() { local rc=$1; shift; log ERROR "$*"; FAIL_REASON="$*"; exit "$rc"; }

[[ -r "$CONFIG" ]] || { log ERROR "config not readable: $CONFIG"; exit "$EX_CONFIG"; }
# shellcheck source=/dev/null
source "$CONFIG"

: "${REMOTE:?REMOTE is required (user@host)}"
: "${SERVER_DIR:?SERVER_DIR is required}"
: "${SYNC_ROOT:?SYNC_ROOT is required}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/mc_mirror_ed25519}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts_mc_mirror}"
MIRROR_DIMS="${MIRROR_DIMS:-minecraft/overworld}"
CHUNK_DIRS="region entities poi"
SERVICE="${SERVICE:-creative.service}"
SCREEN_SESSION="${SCREEN_SESSION:-creative}"
STOP_CMD="${STOP_CMD:-sudo -n systemctl stop $SERVICE}"
START_CMD="${START_CMD:-sudo -n systemctl start $SERVICE}"
BWLIMIT="${BWLIMIT:-0}"
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-600}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-120}"
MAX_SNAPSHOT_AGE_H="${MAX_SNAPSHOT_AGE_H:-30}"
REQUIRE_SAME_VERSION="${REQUIRE_SAME_VERSION:-1}"
WARN_SECONDS="${WARN_SECONDS:-60}"
STOP_TIMEOUT="${STOP_TIMEOUT:-360}"
START_TIMEOUT="${START_TIMEOUT:-300}"
SPACE_MARGIN_MB="${SPACE_MARGIN_MB:-4096}"
LOCK_WAIT="${LOCK_WAIT:-1800}"
SHARED_LOCKS="${SHARED_LOCKS:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

CACHE="$SYNC_ROOT/cache"
INCOMING="$SYNC_ROOT/incoming"
ROLLBACK="$SYNC_ROOT/rollback"
FAILED="$SYNC_ROOT/failed"
SWAP_JOURNAL="$SYNC_ROOT/SWAP_IN_PROGRESS"
STOPPED_MARKER="$SYNC_ROOT/STOPPED_BY_SYNC"
APPLIED="$SYNC_ROOT/APPLIED"
LOG_FILE="$SERVER_DIR/logs/latest.log"
FAIL_REASON=""
WORLD=""
WAS_RUNNING=1

hold_lock() {
  local file=$1 fd
  exec {fd}>>"$file"
  flock -w "$LOCK_WAIT" "$fd" || die "$EX_LOCKED" "lock busy after ${LOCK_WAIT}s: $file"
}

notify() {
  [[ -n "$WEBHOOK_URL" ]] || return 0
  if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
    log WARN "jq or curl missing, webhook skipped"
    return 0
  fi
  local body
  body="$(jq -nc --arg c "[mc-mirror-pull] $1" '{content: $c}')"
  printf 'url = "%s"\n' "$WEBHOOK_URL" |
    curl --config - -fsS -m 10 -H 'Content-Type: application/json' -d "$body" -o /dev/null ||
    log WARN "webhook delivery failed"
}

level_name() {
  local name
  name="$(sed -n 's/^level-name=//p' "$SERVER_DIR/server.properties" 2>/dev/null | tail -n1 | tr -d '\r')"
  name="${name:-world}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != ".." ]] || die "$EX_CONFIG" "unsupported level-name: $name"
  printf '%s\n' "$name"
}

validate_config() {
  local dim v
  for dim in $MIRROR_DIMS; do
    [[ "$dim" =~ ^minecraft/(overworld|the_nether|the_end)$ ]] ||
      die "$EX_CONFIG" "MIRROR_DIMS may only list minecraft/overworld, minecraft/the_nether, minecraft/the_end (got $dim)"
  done
  for v in "$SSH_KEY" "$KNOWN_HOSTS" "$SYNC_ROOT" "$SERVER_DIR"; do
    [[ "$v" != *[[:space:]]* ]] || die "$EX_CONFIG" "paths must not contain whitespace: $v"
  done
  [[ "$SCREEN_SESSION" =~ ^[A-Za-z0-9_-]+$ ]] || die "$EX_CONFIG" "SCREEN_SESSION must match [A-Za-z0-9_-]+"
  [[ -r "$SSH_KEY" ]] || die "$EX_CONFIG" "SSH key not readable: $SSH_KEY"
  [[ -s "$KNOWN_HOSTS" ]] || die "$EX_CONFIG" "pinned known_hosts missing: $KNOWN_HOSTS"
  case "$(realpath -m "$SYNC_ROOT")/" in
    "$(realpath -m "$SERVER_DIR")"/*) die "$EX_CONFIG" "SYNC_ROOT must live outside SERVER_DIR (backups would pick it up)" ;;
  esac
  mkdir -p "$CACHE" "$INCOMING" "$FAILED"
  [[ "$(stat -c %d "$SYNC_ROOT")" == "$(stat -c %d "$SERVER_DIR")" ]] ||
    die "$EX_CONFIG" "SYNC_ROOT and SERVER_DIR must be on the same filesystem so the swap is a rename"
  [[ -f "$WORLD/level.dat" ]] || die "$EX_CONFIG" "no level.dat in $WORLD; create the creative world first"
}

ssh_cmd() {
  printf 'ssh -i %s -p %s -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4' \
    "$SSH_KEY" "$SSH_PORT" "$KNOWN_HOSTS"
}

# Retries only failures that a later attempt can fix (network, timeouts, ssh).
with_retries() {
  local n=1 rc
  while :; do
    rc=0
    "$@" || rc=$?
    case $rc in
      0) return 0 ;;
      10 | 12 | 30 | 35 | 255) ;;
      *) return "$rc" ;;
    esac
    ((n >= RETRIES)) && return "$rc"
    log WARN "attempt $n/$RETRIES failed (rc=$rc), retrying in ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
    n=$((n + 1))
  done
}

fetch_manifest() {
  rsync -t --timeout="$RSYNC_TIMEOUT" -e "$(ssh_cmd)" "$REMOTE:LATEST" "$SYNC_ROOT/LATEST.remote"
}

pull_dim() {
  local stamp=$1 dim=$2
  mkdir -p "$CACHE/$dim"
  # Root-anchored filters: only the three chunk folders and region files in
  # them can ever reach the cache, whatever the export side contains.
  rsync -rt --delete-delay --partial-dir=.rsync-partial \
    --timeout="$RSYNC_TIMEOUT" --bwlimit="$BWLIMIT" -e "$(ssh_cmd)" \
    --include='/region/' --include='/entities/' --include='/poi/' \
    --include='/*/r.*.*.mca' --exclude='*' \
    "$REMOTE:snapshots/$stamp/$dim/" "$CACHE/$dim/"
}

manifest_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null; }

local_mc_version() {
  grep -oE 'Starting minecraft server version [^ ]+' "$LOG_FILE" 2>/dev/null | tail -n1 | awk '{print $NF}'
}

tree_stats() {
  # prints "<files> <bytes>" for region files below the given directories;
  # leftovers in .rsync-partial must not count or verification never passes
  find "$@" -name .rsync-partial -prune -o -type f -name 'r.*.*.mca' -printf '%s\n' 2>/dev/null |
    awk '{n++; s += $1} END {printf "%d %d\n", n, s}'
}

screen_running() {
  screen -ls 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+\.${SCREEN_SESSION}[[:space:]]"
}

server_active() {
  systemctl is-active --quiet "$SERVICE" || screen_running
}

say() {
  screen_running && screen -S "$SCREEN_SESSION" -p 0 -X stuff "say $1"$'\r' || true
}

log_size()  { stat -c %s "$LOG_FILE" 2>/dev/null || echo 0; }
log_inode() { stat -c %i "$LOG_FILE" 2>/dev/null || echo 0; }

wait_log() {
  local re=$1 off=$2 ino=$3 timeout=$4 i
  for ((i = 0; i < timeout; i++)); do
    if [[ "$(log_inode)" != "$ino" ]]; then ino="$(log_inode)"; off=0; fi
    if tail -c +"$((off + 1))" "$LOG_FILE" 2>/dev/null | grep -qE "$re"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_server() {
  if ! server_active; then
    log INFO "creative server is stopped; it will stay stopped after the swap"
    WAS_RUNNING=0
    return 0
  fi
  WAS_RUNNING=1
  if ((WARN_SECONDS > 10)); then
    say "Mirror world refresh: server restarts in ${WARN_SECONDS} seconds."
    sleep $((WARN_SECONDS - 10))
  fi
  say "Mirror world refresh: restarting in 10 seconds."
  sleep 10
  : >"$STOPPED_MARKER"
  $STOP_CMD || die 1 "stop command failed: $STOP_CMD"
  local i
  for ((i = 0; i < STOP_TIMEOUT; i += 2)); do
    server_active || { log INFO "creative server stopped"; return 0; }
    sleep 2
  done
  die 1 "creative server still running after ${STOP_TIMEOUT}s; nothing was swapped"
}

start_server() {
  local off ino
  off="$(log_size)"; ino="$(log_inode)"
  $START_CMD || return 1
  if wait_log '\]: Done \([0-9.]+s\)!' "$off" "$ino" "$START_TIMEOUT"; then
    rm -f "$STOPPED_MARKER"
    return 0
  fi
  return 1
}

dim_path() { printf '%s/dimensions/%s/%s\n' "$WORLD" "$1" "$2"; }

# Moves the live chunk folders aside and the pre-staged ones in. Every step is
# a rename on one filesystem; the journal lets --recover undo a partial swap.
swap_in() {
  local dim d live
  : >"$SWAP_JOURNAL"
  for dim in $MIRROR_DIMS; do
    mkdir -p "$ROLLBACK/$dim" "$WORLD/dimensions/$dim"
    for d in $CHUNK_DIRS; do
      [[ -d "$INCOMING/$dim/$d" ]] || continue
      live="$(dim_path "$dim" "$d")"
      [[ -d "$live" ]] && mv -T -- "$live" "$ROLLBACK/$dim/$d"
      mv -T -- "$INCOMING/$dim/$d" "$live"
    done
  done
  rm -f "$SWAP_JOURNAL"
}

# Puts the rollback copy back. The rejected data goes to $FAILED for analysis.
swap_back() {
  local tag=$1 dim d live
  : >"$SWAP_JOURNAL"
  for dim in $MIRROR_DIMS; do
    for d in $CHUNK_DIRS; do
      [[ -d "$ROLLBACK/$dim/$d" ]] || continue
      live="$(dim_path "$dim" "$d")"
      if [[ -d "$live" ]]; then
        mkdir -p "$FAILED/$tag/$dim"
        mv -T -- "$live" "$FAILED/$tag/$dim/$d"
      fi
      mv -T -- "$ROLLBACK/$dim/$d" "$live"
    done
  done
  rm -f "$SWAP_JOURNAL"
}

recover() {
  local dim d live repaired=0
  if [[ -e "$SWAP_JOURNAL" ]]; then
    log WARN "interrupted swap found, restoring missing chunk folders from rollback"
    for dim in $MIRROR_DIMS; do
      for d in $CHUNK_DIRS; do
        live="$(dim_path "$dim" "$d")"
        if [[ ! -d "$live" && -d "$ROLLBACK/$dim/$d" ]]; then
          mv -T -- "$ROLLBACK/$dim/$d" "$live"
          repaired=1
        fi
      done
    done
    rm -f "$SWAP_JOURNAL"
  fi
  if [[ -e "$STOPPED_MARKER" ]] && ! server_active; then
    log WARN "server was stopped by an interrupted sync, starting it"
    if start_server; then
      notify "recovered: creative server restarted after an interrupted sync (repaired=$repaired)"
    else
      notify "RECOVERY FAILED: creative server did not start, check it by hand"
      return 1
    fi
  fi
  return 0
}

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ "$MODE" == pull ]]; then
    recover || true
    ((rc == EX_LOCKED)) || notify "sync FAILED (rc=$rc): ${FAIL_REASON:-see journal}"
  fi
  exit "$rc"
}

main() {
  WORLD="$SERVER_DIR/$(level_name)"
  mkdir -p "$SYNC_ROOT"
  exec 9>>"$SYNC_ROOT/.pull.lock"
  flock -n 9 || { log WARN "another sync holds the lock"; exit "$EX_LOCKED"; }

  if [[ "$MODE" == recover ]]; then
    recover
    exit $?
  fi

  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  validate_config
  recover

  log INFO "fetching manifest from $REMOTE"
  with_retries fetch_manifest || die "$EX_UNAVAILABLE" "could not fetch LATEST from $REMOTE (rc=$?)"
  local m="$SYNC_ROOT/LATEST.remote" stamp created age dims remote_ver local_ver files bytes dim
  stamp="$(manifest_get snapshot "$m")"
  [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "$EX_STALE" "manifest has no valid snapshot id"
  created="$(manifest_get created_epoch "$m")"
  [[ "$created" =~ ^[0-9]+$ ]] || die "$EX_STALE" "manifest has no created_epoch"
  age=$((($(date +%s) - created) / 3600))
  ((age <= MAX_SNAPSHOT_AGE_H)) || die "$EX_STALE" "snapshot $stamp is ${age}h old (limit ${MAX_SNAPSHOT_AGE_H}h); is the export timer running?"
  dims=" $(manifest_get dims "$m") "
  for dim in $MIRROR_DIMS; do
    [[ "$dims" == *" $dim "* ]] || die "$EX_STALE" "snapshot $stamp does not contain $dim"
  done
  if ((FORCE == 0)) && [[ -r "$APPLIED" && "$(cat "$APPLIED")" == "$stamp" ]]; then
    log INFO "snapshot $stamp already applied, nothing to do"
    exit 0
  fi
  remote_ver="$(manifest_get mc_version "$m")"
  local_ver="$(local_mc_version)"
  if [[ "$remote_ver" != "$local_ver" ]]; then
    if ((REQUIRE_SAME_VERSION)); then
      die "$EX_STALE" "version mismatch: survival ${remote_ver:-unknown}, creative ${local_ver:-unknown}"
    fi
    log WARN "version mismatch: survival ${remote_ver:-unknown}, creative ${local_ver:-unknown}"
  fi
  files="$(manifest_get files "$m")"
  bytes="$(manifest_get bytes "$m")"
  [[ "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || die "$EX_STALE" "manifest lacks files/bytes"

  # The previous rollback is last night's mirror; it is worthless once a new
  # snapshot is due, and dropping it first keeps the peak at about 3x.
  rm -rf -- "$ROLLBACK" "${INCOMING:?}"/*
  local cache_bytes avail need
  read -r _ cache_bytes < <(tree_stats "$CACHE")
  avail="$(df -PB1 --output=avail "$SYNC_ROOT" | tail -n1 | tr -d ' ')"
  need=$((bytes + (bytes > cache_bytes ? bytes - cache_bytes : 0) + SPACE_MARGIN_MB * 1024 * 1024))
  ((avail >= need)) || die "$EX_NOSPACE" "need ~$((need / 1048576)) MiB in $SYNC_ROOT, have $((avail / 1048576)) MiB"

  log INFO "pulling snapshot $stamp ($files files, $((bytes / 1048576)) MiB)"
  : >"$CACHE/.INCOMPLETE"
  for dim in $MIRROR_DIMS; do
    with_retries pull_dim "$stamp" "$dim" || die 1 "rsync of $dim failed (rc=$?); creative server untouched"
  done
  local got_files got_bytes paths=()
  for dim in $MIRROR_DIMS; do paths+=("$CACHE/$dim"); done
  read -r got_files got_bytes < <(tree_stats "${paths[@]}")
  if [[ "$got_files" != "$files" || "$got_bytes" != "$bytes" ]]; then
    die 1 "cache does not match manifest: got $got_files files/$got_bytes B, expected $files/$bytes"
  fi
  cp -- "$m" "$CACHE/MANIFEST"
  rm -f "$CACHE/.INCOMPLETE"

  # Shared locks (e.g. the creative instance's backup lock) are taken only now,
  # so a long transfer never blocks local backups.
  local lock
  for lock in $SHARED_LOCKS; do hold_lock "$lock"; done

  log INFO "pre-staging copy next to the world (server still running)"
  local d
  for dim in $MIRROR_DIMS; do
    for d in $CHUNK_DIRS; do
      [[ -d "$CACHE/$dim/$d" ]] || continue
      mkdir -p "$INCOMING/$dim"
      cp -a --reflink=auto -- "$CACHE/$dim/$d" "$INCOMING/$dim/$d"
      rm -rf -- "$INCOMING/$dim/$d/.rsync-partial"
    done
  done

  stop_server
  log INFO "swapping mirrored dimensions: $MIRROR_DIMS"
  swap_in
  if ((WAS_RUNNING == 0)); then
    printf '%s\n' "$stamp" >"$APPLIED"
    log SUCCESS "applied snapshot $stamp (server left stopped, not start-tested)"
    exit 0
  fi
  if start_server; then
    printf '%s\n' "$stamp" >"$APPLIED"
    find "$FAILED" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf -- {} +
    log SUCCESS "applied snapshot $stamp"
    notify "mirror refreshed to snapshot $stamp"
    exit 0
  fi

  log ERROR "creative server did not come up with snapshot $stamp, rolling back"
  $STOP_CMD || true
  local i
  for ((i = 0; i < STOP_TIMEOUT; i += 2)); do server_active || break; sleep 2; done
  swap_back "$stamp"
  if start_server; then
    die 1 "snapshot $stamp rejected and rolled back; rejected data in $FAILED/$stamp"
  fi
  die 1 "rollback done but the creative server still does not start; check it by hand"
}

main "$@"
```

## 6. systemd integration

### 6.1 survival VM

```ini
# /etc/systemd/system/mc-mirror-export.service
[Unit]
Description=Publish a survival world snapshot for the creative mirror
After=survival.service

[Service]
Type=oneshot
User=mc
Group=mc
ExecStart=/usr/local/bin/mc-mirror-export.sh --config /etc/mc-mirror/export.conf
# Runs even after SIGKILL or a timeout: guarantees save-on.
ExecStopPost=/usr/local/bin/mc-mirror-export.sh --config /etc/mc-mirror/export.conf --ensure-save-on
TimeoutStartSec=1h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SyslogIdentifier=mc-mirror-export
PrivateTmp=true
ProtectSystem=full
```

```ini
# /etc/systemd/system/mc-mirror-export.timer
[Unit]
Description=Nightly survival snapshot for the creative mirror

[Timer]
OnCalendar=*-*-* 04:40:00
Persistent=true

[Install]
WantedBy=timers.target
```

`IOSchedulingClass=idle` is deliberately not used here: during the save-off window the copy should finish quickly, and idle I/O can starve behind the game server.

### 6.2 creative VM

```ini
# /etc/systemd/system/mc-mirror-pull.service
[Unit]
Description=Refresh the creative mirror dimension from survival
Wants=network-online.target
After=network-online.target creative.service

[Service]
Type=oneshot
User=mc
Group=mc
ExecStart=/usr/local/bin/mc-mirror-pull.sh --config /etc/mc-mirror/pull.conf
# Replays an interrupted swap and restarts the server if the sync stopped it.
ExecStopPost=/usr/local/bin/mc-mirror-pull.sh --config /etc/mc-mirror/pull.conf --recover
TimeoutStartSec=3h
Nice=15
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SyslogIdentifier=mc-mirror-pull
PrivateTmp=true
ProtectSystem=full
# No NoNewPrivileges=: the script needs sudo to stop/start creative.service.
```

```ini
# /etc/systemd/system/mc-mirror-pull.timer
[Unit]
Description=Nightly creative mirror refresh

[Timer]
OnCalendar=*-*-* 05:15:00
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

### 6.3 Install and operate

```bash
install -m 755 mc-mirror-export.sh /usr/local/bin/      # survival
install -m 755 mc-mirror-pull.sh   /usr/local/bin/      # creative
install -d -m 750 -g mc /etc/mc-mirror
systemd-analyze calendar '*-*-* 04:40:00'
systemctl daemon-reload
systemctl enable --now mc-mirror-export.timer           # survival
systemctl enable --now mc-mirror-pull.timer             # creative

systemctl start mc-mirror-export.service                # manual run
systemctl list-timers 'mc-mirror-*'
journalctl -t mc-mirror-export -b --no-pager
journalctl -t mc-mirror-pull --since today --no-pager
sudo -u mc /usr/local/bin/mc-mirror-pull.sh --force     # re-apply the current snapshot
```

Logs: journald keeps them (set `SystemMaxUse=` in `journald.conf` if the disk is small). For alerting, set `WEBHOOK_URL` (Discord-style `{"content": ...}` JSON, URL passed on curl's stdin so it never appears in `ps`) or add `OnFailure=` to a notification unit.

### 6.4 Error handling matrix

| Failure | Detected by | Effect | Recovery |
|---|---|---|---|
| Survival VM unreachable / ssh refused | rsync rc 255 | Retried `RETRIES` times; creative untouched | Next night; webhook |
| Transfer interrupted / stalled | rc 30 (`--timeout`), 12, 10 | Retried; partials kept in `.rsync-partial`; `.INCOMPLETE` stays | Next run resumes the delta |
| Snapshot pruned during pull | rc 23/24 | Fails fast (not retried) | Next night pulls the new snapshot |
| Host key changed | rc 255, ssh error in journal | Fails; never auto-accepts | Verify out of band, update `known_hosts_mc_mirror` |
| Export did not run | manifest age > `MAX_SNAPSHOT_AGE_H` | Refused (rc 65) | Fix survival timer |
| Version mismatch | `mc_version` differs | Refused (rc 65) | Upgrade both servers together |
| Disk full (either side) | `df` preflight | rc 73, nothing changed | Free space, raise margin |
| save-all never confirmed | log/RCON wait timeout | Export aborts, save-on sent | Check survival log / disk |
| Export killed in save-off | `.save-off-active` marker | `ExecStopPost --ensure-save-on` | Automatic |
| Creative fails to start on new data | no `Done (` within `START_TIMEOUT` | Rolled back to previous folders | Inspect `failed/<stamp>`; webhook |
| Pull killed mid-swap | `SWAP_IN_PROGRESS` | `ExecStopPost --recover` restores folders, starts server | Automatic |
| Two runs overlap | `flock` | Second exits 75 | None needed |

## 7. itzg/mc-router at the edge

mc-router v1.49.0 (2026-10-20) routes by the hostname the client typed. Two mappings, one per VM:

```json
{
  "default-server": null,
  "mappings": {
    "survival.example.net": "10.8.0.11:25565",
    "creative.example.net": "10.8.0.12:25565"
  }
}
```

```bash
mc-router -port 25565 -routes-config /etc/mc-router/routes.json -routes-config-watch \
  -connection-rate-limit 5
# or flags only:
mc-router -mapping survival.example.net=10.8.0.11:25565 -mapping creative.example.net=10.8.0.12:25565
```

- Without `default-server`, unmapped hostnames (scanners) are refused.
- `-connection-rate-limit` defaults to 1 per second; raise it if many players reconnect at once after the creative restart.
- The VMs are on different hosts and networks: route the backend traffic over a WireGuard tunnel (addresses above are tunnel addresses) instead of exposing 25565 on the creative host publicly, and firewall each backend to accept game traffic only from mc-router.
- Real client IPs (bans, whitelist logs): enable `-use-proxy-protocol` in mc-router **and** install FabricProxy-Lite on both servers in the same change; one without the other breaks every connection. Restrict with `-trusted-proxies`.
- During the nightly swap mc-router simply fails new connections to creative for the restart window; no router change is needed.

## 8. First-time setup order

1. Survival: note the seed (`/seed`), confirm both servers run the same Minecraft and Fabric versions.
2. Creative: install the mod stack, set `level-seed` in `server.properties`, start once so the world, the `fabricplots:plots` dimension and `world_gen_settings.dat` are created fresh (FabricPlots asks for a fresh world on first use). Stop it.
3. Configure Dimensional Inventories pools and FabricPlots (`manage-gamemode=false`).
4. Create the `mcsync` account, export root, key, pinned `known_hosts` (section 4).
5. Install both scripts, configs and units. Run the export by hand, then `mc-mirror-pull.sh` by hand, and watch both journals.
6. Join creative: confirm the mirror matches survival near spawn and that terrain beyond the mirrored area generates seamlessly (seed check). Visit `/plot world`.
7. Enable both timers.
8. In this repo's backup config on creative, exclude the mirrored dimension from creative backups (it is regenerated nightly), e.g. `BACKUP_EXTRA_EXCLUDES` with `/world/dimensions/minecraft/overworld/region` etc.; keep the plot dimension in backups. After restoring such a backup, run `mc-mirror-pull.sh --force` so the mirror is filled again (`APPLIED` still names the old snapshot).
