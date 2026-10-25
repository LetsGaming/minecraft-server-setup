# Creative mirror server: technical blueprint

> **Status (2026-10-26):** the mirror described here is implemented; use [docs/mirror.md](../mirror.md) and `src/mirror/`. The script templates in this document were found to need fixes when they were run (see [2026-10-25-creative-mirror-vm-test-audit.md](2026-10-25-creative-mirror-vm-test-audit.md)); do not copy them.

Goal: a dedicated `creative-server-vm` that mirrors the survival world (same seed, same generated terrain) and also hosts an independent flat plot world, refreshed every 24 hours from `survival-server-vm` over SSH without touching survival performance or data.

Research date: 2026-10-23. Target: Fabric on Minecraft 26.3, Fabric API 0.165.0+26.3, Java 25. See [creative-mirror-audit.md](creative-mirror-audit.md) for evidence and open risks.

## 1. Recommended design in one paragraph

Do not replicate the survival world as an extra dimension. On the creative VM, make the **mirrored survival world the main world** (`dimensions/minecraft/{overworld,the_nether,the_end}`) and add the **plot world as the only custom dimension** (`dimensions/fabricplots/plots`). The sync then overwrites exactly three vanilla dimension folders and can never touch the plot dimension, because the plot data lives in a different namespace folder. No multi-world mod is needed for the mirror itself.

Why this beats "mirror as a second dimension":

- Vanilla portals, the dragon fight, `/seed` and spawn behave exactly as on survival.
- A custom-dimension copy needs the dimension type, noise settings and seed to match by hand, and one mismatch gives chunk seams at the edge of the copied area.
- Fewer moving parts: one mod (FabricPlots) instead of two.

## 2. Recommended mod stack (Fabric 26.3)

| Role | Mod | Version for 26.3 | Notes |
| --- | --- | --- | --- |
| Loader API | Fabric API | 0.165.0+26.3 | Required by everything below. |
| Plot world | FabricPlots | 1.0.2+26.3 | Server-side only. Bundles its own flat plot dimension (`fabricplots:plots`), claims, protection, build tools. Bundles DraftSmith 1.0.1. |
| Menu library | sgui | 2.2.x+26.3 (maven.nucleoid.xyz) | FabricPlots lists it as required and it is not on Modrinth. Confirm whether the 1.0.2+26.3 jar needs it (see audit R3). |
| Inventory split | Dimensional Inventories | 2.2.2+26.3 | Optional but recommended: keeps creative plot inventory out of the mirrored world. |
| Permissions | LuckPerms | v5.5.85-fabric | Optional. Lists 26.3. |
| Performance | Lithium, FerriteCore | check per release | Optional. |

Only needed if you later want extra worlds, not for the mirror:

| Mod | 26.3 status | Use |
| --- | --- | --- |
| Worlds: Multiverse for Fabric 1.10.0+26.3 | Supported, Fabric API only | Paper-Multiverse style `/worlds create`, per-world gamerules. Best general choice. |
| Multiworld 1.14.2 (beta) | Supported, beta | Stores worlds in `dimensions/<id>/<path>`. Beta, so second choice. |
| Multiverse (senseiwells) 0.6.0+26.3 | Supported, also needs a second required library | Smaller feature set, custom dimension types via datapack. |

Not recommended: *Dimenager* and *DimensionsCore* were named in the task but did not appear in any 26.x search result. Treat them as unverified and unsupported.

## 3. Directory layout blueprint (creative VM)

26.1 restructured saves: every dimension, including the Overworld, lives under `dimensions/<namespace>/<path>`. `DIM-1` and `DIM1` no longer exist.

```
/srv/minecraft/creative/
  server.properties            level-name=world, level-seed=<survival seed>
  mods/                        fabric-api, fabricplots, sgui, ...
  world/
    level.dat                  NOT synced (creative's own settings)
    data/                      NOT synced (shared data: scoreboard, weather, raids...)
      minecraft/
        world_gen_settings.dat NOT synced: holds seed AND the dimension list incl. the plot dimension
    players/                   NOT synced (data, stats, advancements stay creative-local)
    dimensions/
      minecraft/
        overworld/             SYNCED  (region, entities, poi, data)
        the_nether/            SYNCED
        the_end/               SYNCED  (includes data/minecraft/ender_dragon_fight.dat)
      fabricplots/
        plots/                 UNTOUCHED (created by FabricPlots; path inferred from id fabricplots:plots)
```

Survival VM keeps its normal layout. Two additions there:

```
/srv/minecraft/mirror-stage/   persistent flushed copy of the three dimensions + .stamp
  overworld/  the_nether/  the_end/
```

Creative VM keeps a persistent pull cache, so each nightly pull is incremental:

```
/srv/minecraft/mirror-pull/{overworld,the_nether,the_end}/
```

Why `world_gen_settings.dat` must not be synced: since 26.1 it carries the seed and the registered dimension set. Overwriting it from survival would drop the plot dimension from the creative world. FabricPlots also says its plot geometry is baked in when the world is created, so the creative world must be **created fresh with FabricPlots installed**, using the survival seed, and then only the dimension folders are replaced.

## 4. One-time setup

### 4.1 Create the creative world

1. On survival, run `/seed`. Note the number.
2. On creative, install Java 25, Fabric 26.3 server, Fabric API, FabricPlots, sgui. Set in `server.properties`:
   ```
   level-name=world
   level-seed=<survival seed>
   gamemode=creative
   force-gamemode=true
   difficulty=peaceful
   ```
   `white-list` defaults to `true` since 26.3 snapshot 2, so add players or set it deliberately.
3. Start once so the world and the plot dimension are generated, then stop.
4. Run the first sync (section 6). Start the server and verify `/seed` equals the survival seed and that `/plot` works.
5. Datapacks and worldgen mods must be identical on both servers or newly generated chunks will not match survival.

### 4.2 SSH key (ed25519), pull model

The creative VM pulls. The survival VM never holds a credential for creative, so a compromised creative VM cannot write to survival.

On creative VM, as the `minecraft` user:

```bash
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -a 64 -N '' -C 'mc-mirror@creative' -f ~/.ssh/mc-mirror_ed25519
ssh-keyscan -t ed25519 survival-server-vm >> ~/.ssh/known_hosts   # then verify the fingerprint out of band
cat ~/.ssh/mc-mirror_ed25519.pub
```

On survival VM, append to `~minecraft/.ssh/authorized_keys` (one line):

```
restrict,command="/usr/local/sbin/mc-mirror-export",from="<creative-vm-ip>" ssh-ed25519 AAAA... mc-mirror@creative
```

`restrict` disables forwarding, pty and agent. The forced command allows only three requests: `ping`, `snapshot`, and a read-only rsync rooted at the stage directory.

## 5. Survival VM scripts

Config, `/etc/mc-mirror/survival.env`:

```bash
MC_DIR=/srv/minecraft/survival
WORLD=world
MC_SCREEN=survival
STAGE=/srv/minecraft/mirror-stage
MIN_FREE_KB=2097152
FLUSH_TIMEOUT=120
COPY_TIMEOUT=600
```

### 5.1 `/usr/local/sbin/mc-mirror-export` (forced command)

```bash
#!/usr/bin/env bash
set -euo pipefail
source /etc/mc-mirror/survival.env

case "${SSH_ORIGINAL_COMMAND:-}" in
  ping)        echo ok ;;
  snapshot)    exec /usr/local/sbin/mc-mirror-snapshot ;;
  "rsync --server --sender "*) exec rrsync -ro "$STAGE" ;;
  *)           echo "denied" >&2; exit 126 ;;
esac
```

`rrsync` ships with the Debian `rsync` package (`command -v rrsync`; on older releases it is under `/usr/share/doc/rsync/scripts/`). It reads `SSH_ORIGINAL_COMMAND` itself and refuses paths outside `$STAGE`.

### 5.2 `/usr/local/sbin/mc-mirror-snapshot`

The whole save-off to save-on window lives in one script on the survival VM, bounded by timeouts and an `EXIT` trap. A dropped SSH session or a crashed puller can therefore never leave survival with saving disabled. The slow network transfer happens afterwards from the stage copy, with the live server already back to normal.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/mc-mirror/survival.env

SRC="$MC_DIR/$WORLD/dimensions/minecraft"
LOG="$MC_DIR/logs/latest.log"
DIMS=(overworld the_nether the_end)

exec 9>"$MC_DIR/.mc-mirror.lock"
flock -n 9 || { echo "snapshot already running" >&2; exit 75; }

mc() { screen -S "$MC_SCREEN" -p 0 -X stuff "$1"$'\r'; }

saving_off=0
cleanup() { [ "$saving_off" = 1 ] && mc "save-on" || true; }
trap cleanup EXIT

screen -ls | grep -q "\.${MC_SCREEN}[[:space:]]" || { echo "screen $MC_SCREEN not running" >&2; exit 69; }

mkdir -p "$STAGE"
rm -f "$STAGE/.stamp"

need_kb=$(du -sk "$SRC" | cut -f1)
free_kb=$(df -Pk "$STAGE" | awk 'NR==2{print $4}')
if [ -z "$(ls -A "$STAGE")" ]; then required=$(( need_kb * 11 / 10 )); else required=$MIN_FREE_KB; fi
[ "$free_kb" -ge "$required" ] || { echo "stage disk too small: ${free_kb}K free, ${required}K needed" >&2; exit 28; }

wait_for_log() {
  local offset=$1 pattern=$2 deadline=$(( SECONDS + FLUSH_TIMEOUT ))
  while [ $SECONDS -lt $deadline ]; do
    tail -c +$(( offset + 1 )) "$LOG" 2>/dev/null | grep -q "$pattern" && return 0
    sleep 1
  done
  return 1
}

off=$(stat -c %s "$LOG")
mc "save-off"; saving_off=1
mc "save-all flush"
wait_for_log "$off" "Saved the game" || { echo "save-all flush did not confirm in ${FLUSH_TIMEOUT}s" >&2; exit 74; }

for d in "${DIMS[@]}"; do
  mkdir -p "$STAGE/$d"
  timeout "$COPY_TIMEOUT" ionice -c3 nice -n19 \
    rsync -a --delete --exclude=session.lock "$SRC/$d/" "$STAGE/$d/"
done

mc "save-on"; saving_off=0
date -u +%Y-%m-%dT%H:%M:%SZ > "$STAGE/.stamp"
echo "snapshot ok"
```

Impact on survival: during the window the server keeps ticking, chunks just stay in memory unsaved. The incremental local rsync of only changed region files normally takes seconds. The first run copies everything, so run it off-peak.

Check the log text once on your build: `Saved the game` is the vanilla confirmation for `save-all`. If your log format differs, adjust the pattern.

## 6. Creative VM: sync workflow

Order of operations in the pull script:

1. **Lock and preflight.** `flock`, check disk, `ssh ... ping` with a connect timeout. Unreachable host means exit 0 with a warning-level log, creative keeps its previous mirror.
2. **Pre-flush on survival.** `ssh ... snapshot` (runs section 5.2 remotely). Failure aborts, nothing local has changed.
3. **SSH transport.** `rsync -a --delete --partial --timeout --bwlimit` of each dimension from `host:<dim>/` into `mirror-pull/<dim>/`, while the creative server is still running. No players are kicked during the transfer.
4. **Sanity gate.** Each pulled dimension must hold at least one `.mca` file, and the overworld region count must not fall below 50 percent of the current one. This stops an empty or half-written stage from wiping the creative mirror.
5. **Stop creative.** Broadcast a warning in game, then `systemctl stop`.
6. **Remote path target isolation.** Local `rsync -a --delete` from `mirror-pull/<dim>/` into `world/dimensions/minecraft/<dim>/` for exactly the three dimension names. Nothing else is a destination, so `dimensions/fabricplots/`, `players/`, `data/` and `level.dat` are never written.
7. **Start creative.** `systemctl start`, also done by the `EXIT` trap if anything failed after step 5.

Downtime is only steps 5 to 7, the local copy of changed files. No rollback copy is kept by default (it would double disk use). Hard links are not a safe shortcut because Minecraft rewrites region files in place. If you want one, use `rsync --backup --backup-dir` in step 6 or take a Proxmox VM snapshot before the first run.

Config, `/etc/mc-mirror/creative.env`:

```bash
SURV_HOST=survival-server-vm
SURV_USER=minecraft
SSH_KEY=/home/minecraft/.ssh/mc-mirror_ed25519
MC_DIR=/srv/minecraft/creative
WORLD=world
MC_SCREEN=creative
MC_UNIT=minecraft-creative.service
PULL=/srv/minecraft/mirror-pull
BWLIMIT_KBPS=20000
MIN_REGION_RATIO_PCT=50
```

### 6.1 `/usr/local/sbin/mc-mirror-pull`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/mc-mirror/creative.env

DIMS=(overworld the_nether the_end)
DEST="$MC_DIR/$WORLD/dimensions/minecraft"
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15
     -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=yes)
REMOTE="$SURV_USER@$SURV_HOST"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

exec 9>"$MC_DIR/.mc-mirror.lock"
flock -n 9 || { log "another sync is running"; exit 75; }

server_stopped=0
cleanup() {
  if [ "$server_stopped" = 1 ]; then
    log "restarting $MC_UNIT"
    sudo -n systemctl start "$MC_UNIT" || log "ERROR: could not restart $MC_UNIT"
  fi
}
trap cleanup EXIT

count_mca() { find "$1" -name '*.mca' 2>/dev/null | wc -l; }

# 1. preflight
mkdir -p "$PULL"
if ! "${SSH[@]}" "$REMOTE" ping >/dev/null 2>&1; then
  log "survival host unreachable, keeping existing mirror"
  exit 0
fi
cur_kb=$(du -sk "$DEST" 2>/dev/null | cut -f1); cur_kb=${cur_kb:-0}
free_kb=$(df -Pk "$PULL" | awk 'NR==2{print $4}')
[ "$free_kb" -ge $(( cur_kb * 12 / 10 + 1048576 )) ] || { log "ERROR: not enough free space for pull"; exit 28; }

# 2. flush and snapshot on survival
log "requesting snapshot"
"${SSH[@]}" "$REMOTE" snapshot

# 3. transfer while creative keeps running
RSYNC_SSH="ssh -i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
for d in "${DIMS[@]}"; do
  mkdir -p "$PULL/$d"
  log "pulling $d"
  rsync -a --delete --partial --partial-dir=.rsync-partial --timeout=120 \
        --bwlimit="$BWLIMIT_KBPS" --exclude=session.lock \
        -e "$RSYNC_SSH" "$REMOTE:$d/" "$PULL/$d/"
done

# 4. sanity gate
for d in "${DIMS[@]}"; do
  [ "$(count_mca "$PULL/$d")" -gt 0 ] || { log "ERROR: pulled $d has no region files, aborting"; exit 65; }
done
old=$(count_mca "$DEST/overworld"); new=$(count_mca "$PULL/overworld")
if [ "$old" -gt 0 ] && [ $(( new * 100 )) -lt $(( old * MIN_REGION_RATIO_PCT )) ]; then
  log "ERROR: overworld regions fell from $old to $new, aborting"; exit 65
fi

# 5. stop creative
screen -S "$MC_SCREEN" -p 0 -X stuff $'say Mirror refresh in 60 seconds, server restarts briefly.\r' || true
sleep 60
log "stopping $MC_UNIT"
sudo -n systemctl stop "$MC_UNIT"; server_stopped=1

# 6. replace only the three mirrored dimensions
for d in "${DIMS[@]}"; do
  mkdir -p "$DEST/$d"
  rsync -a --delete --exclude=session.lock "$PULL/$d/" "$DEST/$d/"
done

# 7. start (also covered by the trap)
sudo -n systemctl start "$MC_UNIT"; server_stopped=0
log "sync complete"
```

Notes:

- Ownership: run as the `minecraft` user on both VMs so files land owned correctly. `rsync -a` run as non-root cannot chown, which is what you want.
- Sudoers on creative (`/etc/sudoers.d/mc-mirror`, edit with `visudo -f`):
  ```
  minecraft ALL=(root) NOPASSWD: /usr/bin/systemctl start minecraft-creative.service, /usr/bin/systemctl stop minecraft-creative.service
  ```
- The unit name `minecraft-creative.service` is an assumption. Its `ExecStop` should send `stop` to the screen session and wait.

### 6.2 systemd units (creative VM)

`/etc/systemd/system/mc-mirror.service`:

```ini
[Unit]
Description=Pull survival world mirror into creative server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=minecraft
Group=minecraft
ExecStart=/usr/local/sbin/mc-mirror-pull
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=idle
# Optional: OnFailure=mc-mirror-failed@%n.service
```

`/etc/systemd/system/mc-mirror.timer`:

```ini
[Unit]
Description=Daily creative mirror refresh

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

Enable: `sudo systemctl daemon-reload && sudo systemctl enable --now mc-mirror.timer`. Manual run: `sudo systemctl start mc-mirror.service`.

## 7. Logging, errors, disk

| Concern | Handling |
| --- | --- |
| Logs | Scripts print timestamped lines to stdout; journald keeps them. Read with `journalctl -u mc-mirror.service -e`. |
| Unreachable host | `ping` check with `ConnectTimeout=15`; exit 0, previous mirror stays live. |
| Dropped link mid-transfer | `--timeout=120`, `ServerAlive*`, `--partial-dir`. A rerun resumes. Creative is still on the old data because the live folders are only touched after a complete, verified pull. |
| Survival never stuck in save-off | Snapshot script owns save-off and restores it in an `EXIT` trap, with flush and copy timeouts. |
| Concurrent runs | `flock` on both VMs (exit 75). |
| Disk space | Survival checks the stage volume; creative checks the pull volume for 1.2x current mirror plus 1 GiB. |
| Empty or truncated source | `.mca` count gate before stopping creative. |
| Stale data | Timer has `Persistent=true`; `.stamp` on survival records the last good snapshot (a monitor can alert if older than 36 hours). |

## 8. Routing (mc-router)

Two hostnames, one backend each, for example `survival.example.com` to survival VM and `creative.example.com` to creative VM:25565, using mc-router mappings. No change to the sync. The creative VM should only accept 25565 from the router and 22 from admin hosts; the survival VM must allow SSH from the creative VM only (also enforced by `from=` in `authorized_keys`).

## 9. Verification checklist (before trusting it)

1. `/seed` on both servers returns the same value.
2. Fly to a survival base on creative after the first sync: terrain and structures match.
3. Run the pull twice. Second run should be fast and report no region changes.
4. Place a block in a plot, run the pull, confirm the plot is intact.
5. Kill the SSH session during `snapshot`: survival log must show `Automatic saving is now enabled`.
6. Unplug the survival network mid-pull: creative stays on old data and starts normally.
