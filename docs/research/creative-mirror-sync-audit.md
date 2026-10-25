# Creative mirror server: research audit

> **Status (2026-10-26):** the mirror described here is implemented; use [docs/mirror.md](../mirror.md) and `src/mirror/`. The script templates in this document were found to need fixes when they were run (see [2026-10-25-creative-mirror-vm-test-audit.md](2026-10-25-creative-mirror-vm-test-audit.md)); do not copy them.

Date: 2026-10-24. Companion to [creative-mirror-sync-blueprint.md](creative-mirror-sync-blueprint.md), which holds the design and the script templates. This document records what was researched, what was found, the risks ranked by severity, how the design answers each one, and what still has to be verified on real servers.

## 1. Scope and method

Questions from the brief:

1. Which dimension/world manager and plot mods work on Fabric 26.3, and how one creative instance can hold a survival-seed mirror plus a flat plot world.
2. How the 26.3 world is laid out on disk.
3. How to copy survival region data to a creative VM on another host every 24 hours over SSH/rsync without harming the live server, while keeping the plot world untouched.
4. SSH key setup, systemd timer integration, logging, network failure handling and disk space checks.

Method:

- Version and compatibility facts came from primary sources: the Fabric meta API, the Modrinth API (per-project version lists filtered to `game_versions=["26.3"]`, `loaders=["fabric"]`), mod READMEs on GitHub, minecraft.wiki changelogs and format pages, the 26.3 language file and vanilla data (misode/mcmeta), the rsync/rrsync/sshd/ssh_config/systemd manuals, the Debian package and security trackers, and the itzg/mc-router README and releases.
- This repo's Bash suite was mapped so the templates match its conventions: `src/scripts/common/server_control.sh`, `src/scripts/backup/**`, `src/scripts/common/utils.sh`, `src/scripts/world/lib/world.js`, `src/setup/management/*`.
- Existing documents in `docs/research/` were deliberately not read, as the brief asked.
- The script templates were checked with `bash -n` and ShellCheck 0.11 (`-S style`, with this repo's `.shellcheckrc` exclusions): clean. They were **not executed** against real servers: the workstation has no rsync, WSL or Docker. Section 6 lists what to verify.

Confidence labels: **V** verified against a cited source on 2026-10-24; **I** inferred (reasoning, recollection or a summarised source); **T** must be tested on the target servers.

## 2. Executive summary

- **Fabric 26.3 is current and well supported** (Minecraft 26.3 released 2026-09-15, DataVersion 5023; Fabric Loader 0.20.1; Fabric API 0.165.0+26.3). V
- **Two of the mods named in the brief do not exist** for 26.3: "Dimenager" and "DimensionsCore" have no Modrinth project, and there is no PlotSquared for Fabric. V. Four real world managers do have 26.3 builds (mc-worlds, World Manager, Multiworld, Multiverse), and **FabricPlots 1.0.2+26.3 is the only grid-plot mod** for 26.3. V
- **No world manager can reload a dimension from disk while the server runs.** Overwriting region files under a loaded dimension is unsafe. Every correct design therefore stops the creative server (or at least unloads the dimension) to swap data. I (no mod documents such a feature; consistent with how chunk caching works and with RegionCast's design, which copies only when the server is stopped)
- Given that, the simplest robust layout is: **mirror = the creative server's own overworld**, created with the survival seed; **plot world = FabricPlots' own `fabricplots:plots` dimension**. No world manager is needed.
- **The 26.1 storage change matters**: the overworld now lives in `world/dimensions/minecraft/overworld/{region,entities,poi}`, the nether and end in `dimensions/minecraft/the_nether|the_end`, players in `players/`, and global data in namespaced `data/minecraft/`. V. Older tutorials that copy `world/region` or `DIM-1` silently copy nothing.
- **Safety model**: survival writes an immutable local snapshot (one short `save-off` window, or none at all by reusing this repo's backup staging mirror); creative pulls it with a read-only `rrsync` key; creative downtime is limited to a rename swap of pre-staged folders; every failure path leaves the creative server on its previous data and the survival server saving.
- **Security finding**: Debian bookworm's rsync (3.2.7-1+deb12u6) is listed as vulnerable to CVE-2026-53783, an rrsync restricted-directory escape. Trixie is fixed only in trixie-security (3.5.0). The design isolates the key in a dedicated account so an escape exposes only the export tree's neighbours, not the server's secrets. V (Debian security tracker)

## 3. Mod research: Fabric 26.3 landscape

### 3.1 Platform

| Item | Finding | Label |
|---|---|---|
| Minecraft 26.3 "Wilderness Bound" | Stable, released 2026-09-15; DataVersion 5023, protocol 777, data pack format 121 | V |
| Newer versions | Only 26.4 snapshots (unstable) | V |
| Fabric Loader | 0.20.1 stable (2026-10-19) | V |
| Fabric API | 0.165.0+26.3 (2026-10-23); 8 builds for 26.3 | V |
| Java | 25 required (stated by mc-worlds, FabricPlots, RegionCast) | V |

### 3.2 Dimension / world managers

| Mod (Modrinth slug) | 26.3 build | Side | License | Create command | Seed per world | Flat | On-disk location | Runtime unload/reload |
|---|---|---|---|---|---|---|---|---|
| Worlds: Multiverse for Fabric (`mc-worlds`) | 1.10.0+26.3 (2026-10-07) | server, client optional | MIT | `/worlds create <id> [seed]`, `from-preset minecraft:flat` | yes V | yes V | `dimensions/minecraft/<id>` I | Auto-unload 1 min after last player; no reload-from-disk |
| World Manager (`melius-worldmanager`) | 1.5.1+26.3 (2026-09-24) | server only | MIT | `/wm create <id>` (GUI), `/wm create <id> <path>` imports a world folder | yes V | yes (GUI) V | Fantasy persistent level I | Delete only |
| Multiworld (`multiworld`) | 1.14.2 (beta, 2026-10-09) | server, client optional | LGPL-3.0+ | `/mw create <id> NORMAL -g=FLAT -s=<seed>` | yes V | yes V | `world/dimensions/<id>/<path>` V | load/unload "coming soon" |
| Multiverse (`multiverse-dimensions`) | 0.6.0+26.3 (2026-09-15) | server only | MIT | `/multiverse create from <type> <id> <seed?>` | yes V | `multiverse:flat` V | `getDimensionPath` V | `clone` copies region files, "may hang your server" |
| Custom Dimensions (`custom-dimensions`) | 1.3.1 | server only | All rights reserved | `/dimension create`, restart required | no | no | datapack | no |
| Fantasy (NucleoidMC library) | v0.8.4+26.3 | library | | API | yes | void generator | | create/unload/delete at runtime; persistent levels must be re-opened by the consumer at startup V |
| Quantum, Into the Multiverse, Superflat/Flat Dimensions | no 26.3 build (newest 1.21.1 / 1.20.4 / 1.21.10) | | | | | | | |
| Dimenager, DimensionsCore, Multiverse-Fabric | no Modrinth project (404); not found by search with the 26.3 facet. CurseForge was not checked. | | | | | | | |

### 3.3 Plots and protection

| Mod | 26.3 build | Notes | Label |
|---|---|---|---|
| **FabricPlots** (`fabricplots`) | 1.0.2+26.3 (2026-09-24), MIT, server only | Ships flat dimension `fabricplots:plots` with a road grid; `/plot claim/auto/home/visit/menu/world/admin`; merging, per-plot biome/PvP, build tool jailed to the plot (bundled DraftSmith). Forces creative in the plot world unless `manage-gamemode=false`. Plot geometry is fixed in code; README asks for a fresh world the first time. Modrinth description still says "26.1.2 & 26.2" but a 26.3 file exists; GitHub releases lag Modrinth. | V |
| PlotSquared | no Fabric port | | V |
| Flan, GOML ReServed, Open Parties and Claims, Claims | 26.3 builds exist | Area claims inside an existing world, not a plot grid | V |
| Leukocyte (`leukocyte`) | 0.4.1+26.3 | Dimension-wide rule authorities (`break`, `place`, `interact_blocks`, `pvp`, `portals`, ...): can make the mirror read-only | V |
| Dimensional Inventories (`dimensional-inventories`) | 2.2.2+26.3 | Dimension pools with separate inventory/ender chest/XP and a pool gamemode; FabricPlots' README documents the pairing | V |
| LuckPerms | v5.5.85-fabric | | V |
| Panda Per-World-Seed (`pandaperworldseed`) | 1.2.0+26.3, CC0 | Per-dimension seed override in `config/per_world_seed.json` | V |
| RegionCast (`regioncast`) | 1.0.2+26.3, MIT, 83 downloads | Built for mirroring: pulls changed region files from a source world while the destination is stopped, sends `save-off`/`save-all flush` to the source over RCON, keeps 3 undo steps. Needs filesystem access to both worlds (a cross-host mount) and documents only dimensions -1/0/1; 26.x path handling not checked. | V / I |
| Multiworld Inventories, GMPerms, Universal Perms | no 26.3 build | | V |

### 3.4 Vanilla datapack dimensions

- Path is `data/<namespace>/dimension/<name>.json` (singular, unchanged); `dimension_type` references must use an existing type such as `minecraft:overworld` because the 26.x dimension_type schema changed (`attributes`, `default_clock`, `timelines`). V
- Flat generator JSON matches vanilla 26.3 `world_preset/flat.json` (`minecraft:flat` with `layers`, `biome`, `features`, `lakes`, `structure_overrides`). V
- **A datapack noise dimension cannot have its own seed** since 1.19 (22w11a removed the `seed` field); all dimensions use the level seed. V. That rules out "a second overworld-like dimension with the survival seed" unless the creative level seed already equals the survival seed, or Panda Per-World-Seed overrides it.
- New datapack dimensions register only on a full restart. I

### 3.5 Recommendation and why

| Option | Mirror | Plots | Verdict |
|---|---|---|---|
| **A. Recommended** | Creative's own `minecraft:overworld`, `level-seed` = survival seed | FabricPlots dimension | Fewest mods; dimension ids identical to survival, so villager memories (GlobalPos), lodestone compasses and portal links stay valid; the swap is a plain stop/rename/start. |
| B. Fallback | `mc-worlds` dimension (`/worlds create mirror <seed>`), swapped while unloaded | FabricPlots | Lets the creative overworld be something else (a hub). Swapping while the server runs depends on the world staying unloaded: there is no lock API, so a player teleporting in mid-swap races the copy. Only acceptable with a stop/start anyway, which removes the benefit. Copied villagers and lodestones reference `minecraft:overworld`, not the mirror id. |
| C. No world manager | Datapack noise dimension + Panda Per-World-Seed | Datapack flat dimension | Works, but no plot grid and a hand-maintained 26.x datapack. |

## 4. Findings and risks

Ranked by severity for this deployment. Each lists the answer in the blueprint.

### High

**F-01 Region files cannot be replaced under a running dimension.** The server caches loaded chunks, keeps region files open and writes chunks back on save/unload. Writing new `.mca` files underneath it yields a mix of old and new data, or new data overwritten by stale cached chunks. No 26.3 manager offers "reload dimension from disk" (I; consistent with RegionCast copying only in `SERVER_STOPPED`). Multiverse's `clone` copies inside the running server and its README warns it can hang the server. V
*Answer:* the creative server is stopped for the swap. To keep that short, the new data is copied next to the world first (`mirror-sync/incoming/`, same filesystem) while the server still runs; the stopped phase is only a few `rename(2)` calls. A journal (`SWAP_IN_PROGRESS`) plus `ExecStopPost=--recover` makes a crash mid-swap repairable.

**F-02 `save-off` must always be undone, and must not be shared blindly.** In vanilla, while saving is off chunks are not unloaded (they could not be saved), so memory grows for the length of the window. V (Paper maintainers, PaperMC#10657 and SPIGOT-6383). If the job dies with saving off, a later crash loses everything since. A second, subtler issue: this repo's backup also toggles `save-off`; an export that sends `save-on` while a backup is mid-copy would end the backup's window early and let it archive torn region files. I
*Answer:* `.save-off-active` marker written before `save-off`; EXIT trap sends `save-on`; `ExecStopPost=--ensure-save-on` covers SIGKILL and timeouts; `timeout SAVE_OFF_MAX` caps the copy; the export takes the repo's `.backup.lock` and the instance operation lock (`SHARED_LOCKS`) so it can never interleave with a backup, restore or rollback. `SOURCE_MODE=stage` removes the extra save-off window completely.

**F-03 rrsync restricted-directory escape (CVE-2026-53783) on Debian.** Per the Debian security tracker (checked 2026-10-24): rrsync could be escaped through a TOCTOU symlink race and options it failed to block; fixed upstream in rsync 3.5.0 (2026-08-13); **bookworm 3.2.7-1+deb12u6 vulnerable**, trixie release pocket 3.4.1 vulnerable, fixed in trixie-security 3.5.0+ds1-0+deb13u1 (DSA-6527-1). Other 2026 rsync CVEs are also listed as open on bookworm. V
*Answer:* (1) the key belongs to a dedicated `mcsync` account, not the server user, so an escape cannot read `variables.txt`, RCON passwords or the live world; (2) `from=` pins the creative VM's address; (3) `authorized_keys` is root-owned; (4) the export tree contains only regular files written by the export (no symlinks for a race to exploit; `rsync -rt` without `-l` skips links); (5) run trixie with trixie-security, or keep SSH reachable only over WireGuard on bookworm until a fix lands. Re-check the tracker before deploying.

**F-04 26.1 moved every dimension.** Overworld: `dimensions/minecraft/overworld/{region,entities,poi}` (and its per-dimension `data/minecraft/{raids,world_border,chunk_tickets}.dat`); Nether/End: `dimensions/minecraft/the_nether|the_end`; custom: `dimensions/<ns>/<path>/`; players: `players/{data,stats,advancements}`; global data: `data/minecraft/*.dat` including `world_gen_settings.dat` (the seed), `game_rules.dat`, `maps/<n>.dat`. V (minecraft.wiki level format, 26.1 changelog). 26.3 snap7 added `version_history` to `level.dat`. V
*Answer:* all paths in the templates use the 26.x layout; the export refuses a world without `dimensions/`; dimensions come from an allowlist.

### Medium

**F-05 Copy scope: chunk folders only.** Chunk NBT carries no seed or world UUID, so `region/`, `entities/` and `poi/` can move between worlds (I; the chunk format lists no such tag). Copying `level.dat`, `data/` or `players/` would overwrite creative's own state (scoreboard, game rules, plot ownership data kept by mods, player inventories). Side effects of not copying `data/`: maps in item frames or chests show blank or a different creative map (map ids are global, `data/minecraft/maps`); active raids and forceloaded chunks do not carry over. `poi/` is rebuilt from chunk data when sections load, but copying it avoids a rebuild. V/I
*Answer:* four layers of isolation (blueprint section 3.4). Map blanking is documented as accepted.

**F-06 Version parity.** Chunks written by 26.3 (DataVersion 5023) cannot be loaded by an older server; a newer server upgrades them on load, and 26.3 can run a full world upgrade at startup (management protocol `world/upgrade_*` notifications). V
*Answer:* the manifest records `mc_version` from the survival log; the pull refuses a mismatch (`REQUIRE_SAME_VERSION=1`). Upgrade both servers in the same maintenance window, survival last.

**F-07 Seed must match, and the seed moved.** Chunks outside the mirrored area generate with creative's seed; a different seed makes hard seams (`blending_data` only blends old-version chunks). I. Since 26.1 the seed lives in `data/minecraft/world_gen_settings.dat`, not `level.dat`, so old "edit level.dat" advice no longer works. V
*Answer:* set `level-seed` in `server.properties` before the creative world is first created; record the seed in the manifest; check the edge of the mirrored area after the first sync. Panda Per-World-Seed is the fallback for an existing creative world.

**F-08 `save-all flush` freezes the survival server briefly.** The wiki: "saved to the data storage device immediately, freezing the server for a short time." V. Length scales with dirty chunks. I
*Answer:* run at 04:40 off-peak, after the hourly backup at hh:20 (fewer dirty chunks); the script logs the save-off window length. `SOURCE_MODE=stage` avoids any extra flush by reusing the flush the backup already did.

**F-09 Ecosystem maturity.** FabricPlots is at 1.0.x with one maintainer, a stale Modrinth description and fixed plot geometry; mc-worlds is a 2026 project with very few users; RegionCast has 83 downloads. V
*Answer:* the recommended design depends only on FabricPlots (for plots) and on vanilla behaviour (for the mirror). Pin exact jar versions, test upgrades on a copy, keep FabricPlots' plot dimension in creative backups.

**F-10 Two hosts on different networks.** SSH (sync) and Minecraft (mc-router to creative backend) both cross networks. Exposing SSH on the survival host to the internet for one automation key, or the creative game port publicly, widens the attack surface. I
*Answer:* WireGuard between the hosts (or between mc-router and both backends); `from=` on the key uses the tunnel address; backends accept 25565 only from mc-router. If real client IPs are needed, enable PROXY protocol in mc-router and FabricProxy-Lite on both servers together (FabricProxy-Lite 26.3 availability was not verified).

**F-11 Pull vs push.** Push (survival initiates) lets one script own the whole sequence but needs a write-capable key for creative stored on survival, the more exposed public server; a survival compromise could then overwrite creative. Pull keeps survival credential-free and the key read-only. Its cost is coordination: creative cannot trigger the flush. V/I
*Answer:* pull, with coordination by schedule and manifest (stale or already-applied snapshots are refused), so neither side needs to command the other.

**F-12 Disk space.** Creative needs about 3x the mirrored dimension size (cache + live + rollback; peak is also 3x because the old rollback is dropped before pre-staging). Survival needs one full snapshot the first time, then only changed files per night (hard links via `--link-dest`). I
*Answer:* both scripts check `df` against an estimate plus margin and exit 73 without changing anything if short. Reflink-capable filesystems (btrfs, XFS) make pre-staging nearly free.

### Low

**F-13 rsync flag pitfalls.** `-z` wastes CPU on zlib/lz4 chunk payloads; `--checksum` reads every byte on both sides; `--inplace` leaves files inconsistent if interrupted and breaks `--link-dest` hard links; `-a` adds owner/group/device handling (rrsync 3.5 forces `--no-D`); `--contimeout` applies to daemon mode only, so SSH needs `ConnectTimeout`/`ServerAliveInterval`. V (rsync man page)
*Answer:* `-rt --partial-dir --delete-delay --timeout --bwlimit` and ssh options as in the templates.

**F-14 `ionice` idle is not a dependable throttle.** It only works with I/O schedulers that honour classes (BFQ); with `none`/`mq-deadline` it does nothing. I
*Answer:* `--bwlimit` on the pull is the dependable cap; `nice`/`ionice` stay as best-effort extras.

**F-15 Log-based completion detection.** Waiting for `Saved the game` must be anchored (`\]: Saved the game$`) so chat cannot fake it, must start after a recorded byte offset, and must follow `latest.log` rotation at server start. The exact 26.x strings are "Automatic saving is now disabled", "Saving the game (this may take a moment!)", "Saved the game", "Unable to save the game (is there enough disk space?)". V. This repo's existing pattern `\]: Saved the (game|world)` is already anchored correctly.
*Answer:* implemented in `wait_log` (offset plus inode tracking) in both templates.

**F-16 Players in the mirror.** Builds in the mirror vanish nightly; a player who logged out in the mirror may log in inside terrain that changed. I
*Answer:* separate inventory pool and gamemode via Dimensional Inventories, a join message or MOTD, optional Leukocyte read-only mode, and a 60-second in-game warning before each swap.

**F-17 `region-file-compression`.** Survival and creative may use deflate, lz4 or none. Each chunk records its compression type, so mismatched settings should still read; keep both on the same value anyway. V (property exists since 1.20.5) / I (cross-reading)

**F-18 RCON is unencrypted.** V (wiki). If RCON replaces screen, bind it to localhost and keep the password in a root-owned config.

### Informational

**F-19** The Minecraft management protocol (JSON-RPC over WebSocket, since 1.21.9, disabled by default) has a `save` method and, in 26.3, world-upgrade notifications. It could later replace screen/RCON for confirmed saves. V
**F-20** itzg/mc-router v1.49.0 (2026-10-20) supports a routes JSON with hot reload (`-routes-config-watch` or SIGHUP), refuses unmapped hostnames when no default is set, and rate-limits connections to 1/s by default. V

## 5. Fit with this repository

| ID | Finding | Implication |
|---|---|---|
| R-01 | No SSH, cross-host, sync or mc-router code exists; `docs/reverse-proxy.md` covers only the API wrapper on port 3030. | The mirror is a new feature area, not an extension of existing code. |
| R-02 | The backup staging mirror (`$BACKUPS_PATH/.stage/mirror`) is a flushed full copy refreshed hourly, but it only persists with `BACKUP_STAGING_MODE=mirror`; `auto` picks reflink snapshots when available and keeps no mirror. `bk_private_dir` keeps `.stage` at mode 700, strips ACLs and requires single-owner files, so another account cannot read it. The refresh uses temp-plus-rename (no `--inplace`), so hard links into it would be content-safe, but permissions rule them out. | `SOURCE_MODE=stage` copies (with `--link-dest` between export snapshots) instead of hard-linking the staging mirror, and requires `BACKUP_STAGING_MODE=mirror`. |
| R-03 | The repo schedules with **cron** (`create_backup_job.sh`, `create_restart_job.sh`, helpers in `cron_lib.sh`); there are no systemd timers. The brief asks for systemd timers. | The templates use timers as requested. If the feature moves into the repo, decide between a new timer pattern (better: `Persistent=`, `ExecStopPost=` recovery, journald) and cron consistency. **Open decision for the maintainer.** |
| R-04 | Locks: backups take `$BACKUPS_PATH/.backup.lock` (`flock -n`, fd 9) and the instance operation lock `scripts/<inst>/.locks/operation_<inst>.lock`; restore, rollback, restart and the scheduled restart take the operation lock and exit 75 when it is held. `graceful_stop.sh` and `start.sh` take no lock. | Listing both files in `SHARED_LOCKS` serializes the export/pull with all of them. A backup that collides is skipped (exit 75) rather than blocked; `BACKUP_SKIP_ALERT_AFTER` (3) alerts only on repeated skips. The pull can stop/start the unit while holding the operation lock. The templates do not write the repo's `.kind` helper file, so the repo's "held by" message would show a stale kind. |
| R-05 | Webhooks: `tests/js/webhookEvents.test.cjs` fails if a script emits an event missing from `KNOWN_WEBHOOK_EVENTS` (`src/setup/common/loadVariables.js`). | An integrated version should add events such as `mirror_export_failed`, `mirror_sync_complete`, `mirror_sync_failed` there and in the README, and use `notify` from `src/scripts/common/webhook.sh`. |
| R-06 | Config flows from `variables.json` through `set_common_variables.js` into `variables.txt`; optional keys must be listed there and validated in `loadVariables.js` and `bk_load_config`. | An integrated version needs a `MIRROR` block in `variables.example.json` plus those three touch points. |
| R-07 | Creative backups archive the whole server directory. | Exclude the mirrored dimension's chunk folders with `BACKUP_EXTRA_EXCLUDES` (anchored rsync patterns such as `/world/dimensions/minecraft/overworld/region`); keep `mirror-sync/` outside `SERVER_DIR` (the pull enforces it). After restoring such a backup run the pull with `--force`. |
| R-08 | `src/scripts/world/lib/world.js` (`discoverDimensions`) already understands the 26.x layout and datapack dimensions. | Chunk pruning on survival (`prune-chunks.js`) shrinks every future transfer; pruning the mirror on creative is pointless (overwritten nightly). |
| R-09 | Shell tests use shims (`tests/shell/shims/`) and have no `ssh` shim; the backup suites are known to hang under Git Bash on Windows. | Tests for an integrated version need an `ssh` shim modelled on the `rsync` one and should run on Linux CI. |
| R-10 | Instance units use `PrivateTmp=true`, `ProtectSystem=full`, no `NoNewPrivileges` (screen and sudo). | The pull unit mirrors that (it needs sudo); the export unit could be hardened further, but `ProtectSystem=full` was kept to avoid breaking screen's socket access. |

## 6. Verification checklist before production

Run on staging copies of both servers. Items marked **T** in the findings.

1. `save-all flush` during `save-off` writes region files (check `.mca` mtimes) and logs exactly `]: Saved the game` on Fabric 26.3; RCON reply contains the same text.
2. Memory growth during a worst-case save-off window (busy evening world) stays within the heap; note the logged window length.
3. FabricPlots creates `fabricplots:plots` in a world whose overworld is later replaced by the sync, and plots survive several swaps unchanged (compare `dimensions/fabricplots/plots/region` checksums before and after).
4. rrsync on the actual Debian version accepts the pull's options (`--delete-delay`, `--partial-dir`, `--timeout`, `--bwlimit` are receiver-side or allowed; confirm with a dry run) and refuses `ssh ... id`, writes and paths outside the export root.
5. `apt-cache policy rsync` shows a version fixed for CVE-2026-53783 (trixie-security 3.5.x) or the SSH port is reachable only through WireGuard.
6. The creative server loads mirrored chunks without "Failed to read chunk" or datafixer errors, and the edge of the mirrored area shows no seam (seed check).
7. Kill tests: `systemctl kill -s KILL mc-mirror-export.service` during the save-off window leads to `save-on` via `ExecStopPost`; `kill -9` of the pull between the two `mv` calls is repaired by `--recover` and the server restarts.
8. Network tests: block the survival host mid-transfer (`iptables -I OUTPUT -d <survival> -j DROP`), confirm retries, then confirm the next run resumes from `.rsync-partial` and that the creative server was never stopped.
9. Disk tests: shrink free space below the estimate; both scripts exit 73 without changing anything.
10. A backup and a restore started during the export/pull are skipped with exit 75 (not run concurrently).
11. Swap downtime measured end to end (stop warning to `Done`) is acceptable; mc-router reconnects players afterwards.

## 7. Integration roadmap (if this moves into the suite)

| Item | Value | Effort | Notes |
|---|---|---|---|
| Ship both scripts under `src/scripts/mirror/`, sourcing `server_control.sh` (`save_and_wait`, `disable_auto_save`, `enable_auto_save`), `utils.sh` (`acquire_operation_lock`) and `webhook.sh` instead of local copies | High | M | Reuses the confirmed-save logic and lock semantics already tested |
| `MIRROR` config block + validation + `KNOWN_WEBHOOK_EVENTS` entries | High | S | R-05, R-06 |
| `manage.sh mirror export|pull|status` and a `doctor.sh` check (age of `APPLIED`/`LATEST`, `.save-off-active` leftovers, cache `.INCOMPLETE`) | Medium | S | |
| Scheduler decision (timers vs cron) | Medium | S | R-03 |
| Wizard route for "creative mirror" (mod stack download, `level-seed`, key setup instructions) | Medium | L | |
| Shell tests with an `ssh` shim; real-tool CI job | High | M | R-09 |
| Management protocol client for confirmed saves | Low | M | F-19 |

## 8. Sources

Platform and mods:
- https://meta.fabricmc.net/v2/versions/game, https://meta.fabricmc.net/v2/versions/loader
- https://api.modrinth.com/v2/project/fabric-api/version
- https://minecraft.wiki/w/Java_Edition_26.1, https://minecraft.wiki/w/Java_Edition_26.2, https://minecraft.wiki/w/Java_Edition_26.3, https://minecraft.wiki/w/Data_version
- https://raw.githubusercontent.com/misode/mcmeta/26.3-summary/version.json
- https://modrinth.com/mod/mc-worlds, https://github.com/Wroud/mc-worlds
- https://modrinth.com/mod/melius-worldmanager, https://github.com/DrexHD/WorldManager
- https://modrinth.com/mod/multiworld, https://github.com/IsaiahMC/multiworld
- https://modrinth.com/mod/multiverse-dimensions, https://github.com/senseiwells/Multiverse
- https://github.com/NucleoidMC/fantasy (README, release v0.8.4+26.3)
- https://modrinth.com/mod/fabricplots, https://github.com/beachfury/fabricplots
- https://modrinth.com/mod/dimensional-inventories, https://modrinth.com/mod/leukocyte, https://modrinth.com/mod/luckperms
- https://modrinth.com/mod/pandaperworldseed, https://modrinth.com/mod/regioncast, https://github.com/CodeW4VE/RegionCast

World format and commands:
- https://minecraft.wiki/w/Java_Edition_level_format, https://minecraft.wiki/w/Java_Edition_26.1_Snapshot_6
- https://minecraft.wiki/w/Region_file_format, https://minecraft.wiki/w/Chunk_format
- https://minecraft.wiki/w/Dimension_definition
- https://raw.githubusercontent.com/misode/mcmeta/26.3-data/data/minecraft/worldgen/world_preset/flat.json
- https://minecraft.wiki/w/Commands/save, https://minecraft.wiki/w/RCON
- https://raw.githubusercontent.com/InventivetalentDev/minecraft-assets/26.1/assets/minecraft/lang/en_us.json
- https://github.com/PaperMC/Paper/issues/10657, SPIGOT-6383
- https://github.com/itzg/docker-mc-backup

Transport, security, scheduling, routing:
- https://download.samba.org/pub/rsync/rsync.1, https://download.samba.org/pub/rsync/rrsync.1
- https://raw.githubusercontent.com/RsyncProject/rsync/master/NEWS.md
- https://security-tracker.debian.org/tracker/CVE-2026-53783
- https://packages.debian.org/bookworm/amd64/rsync/filelist, https://packages.debian.org/trixie/amd64/rsync/filelist
- https://sources.debian.org/api/src/rsync/, https://sources.debian.org/api/src/systemd/
- https://man.openbsd.org/sshd.8, https://man.openbsd.org/ssh_config.5
- https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html, systemd.service.html, systemd.exec.html
- https://github.com/itzg/mc-router (README), https://api.github.com/repos/itzg/mc-router/releases
- https://modrinth.com/mod/fabricproxy-lite

Repository files consulted: `src/scripts/common/server_control.sh`, `src/scripts/common/utils.sh`, `src/scripts/common/webhook.sh`, `src/scripts/common/graceful_stop.sh`, `src/scripts/backup/backup.sh`, `src/scripts/backup/lib/{bk_common,bk_stage,bk_state}.sh`, `src/scripts/backup/automation/scheduled_restart.sh`, `src/scripts/{restart,smart_restart,rollback}.sh`, `src/scripts/backup/restore.sh`, `src/scripts/world/lib/world.js`, `src/setup/management/{create_service,create_backup_job,cron_lib}.sh`, `src/setup/common/loadVariables.js`, `tests/js/webhookEvents.test.cjs`, `docs/backup-restore.md`, `docs/reverse-proxy.md`, `docs/sudoers-setup.md`, `.shellcheckrc`.
