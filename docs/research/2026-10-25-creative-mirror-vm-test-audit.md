# Creative mirror: two-VM empirical test audit

Date: 2026-10-25. Status: executed on a Proxmox test host against a live Minecraft 26.3 stack. This document tests the design in [creative-mirror-combined-audit.md](creative-mirror-combined-audit.md) and promotes or refutes its T/R/I items. Evidence labels are the same as there (V, R, I, T, C). **V** here means observed in this test run, with the command output seen.

## 0. Summary

- The canonical v2 design works end to end over a real LAN: export on survival, pull over a pinned-key read-only `rrsync` account, swap on creative, health check, idempotent re-run. Plots, `level.dat`, `data/` and `players/` are untouched by the swap (V).
- **The templates as written do not run on 26.3 / Debian 13.** Three defects were found and patched during the run (P1 to P3, section 5). Without P2 the export aborts on every run, because 26.3 changed the log format of the save confirmation.
- **The suite's own confirmed-save pattern is broken for screen mode on 26.3** (`server_control.sh:340`). RCON mode is unaffected.
- Three design gaps were found that the audit did not know about: partial-swap recovery (fixed by P3), `rm` of the rollback before the space check, and `ExecStopPost` being killed by a cgroup-wide SIGKILL.
- The shrink guard gap (F-15) is real and was demonstrated: an 8 KiB snapshot replaced an 8 MiB mirror with no complaint. Still unported.
- C2ME makes generation parity clearly worse (about 3 times more differing blocks than vanilla against vanilla). Vanilla alone is not deterministic either (MC-55596 reproduces on 26.3).
- Player-dependent items (inventory separation, `force-gamemode` flapping) could not be tested: no bot library speaks protocol 777.

## 1. Test environment

| Item | Value |
|---|---|
| Host | Proxmox VE 9.2.4, 4 cores, 31 GB RAM, `local-lvm` thin pool |
| Pre-existing VMIDs (untouched) | 100 `minecraft`, 101 `fall-students`, 102 `template`, 200 `palworld-01` |
| VMIDs created | 9000 (Debian 13 template), 9101 `survival-test`, 9102 `creative-test`. 9001 (scratch clone of 102) was destroyed early |
| Network | both VMs on `vmbr0`, same /24, DHCP (192.168.2.197 survival, 192.168.2.241 creative) |
| OS | Debian 13.5 trixie, rsync 3.5.0+ds1-0+deb13u1, OpenSSH, Java 25.0.4.1 (openjdk-25-jre-headless) |
| Pins (identical both VMs, sha512 verified) | Minecraft 26.3 (DataVersion 5023), Fabric Loader 0.20.1, Fabric API 0.165.0+26.3, C2ME 0.4.2-alpha.0.106+26.3; creative only: FabricPlots 1.0.2+26.3, Dimensional Inventories 2.2.2+26.3 |
| Seed | `-446251370538060616` (your choice), set in `level-seed` on both before first world creation |
| Suite | working tree copied to `/home/mc/suite` on both VMs, installed with `main.sh --vanilla`, RCON enabled |

**Deviation 1: template 102 is not Debian.** It is Ubuntu 24.04.4 LTS (rsync 3.2.7-1ubuntu1.5); its `debian12` tag is wrong. At your request I built a new Debian 13 template from the official `debian-13-genericcloud-amd64` image (checksum verified). Production is Debian 13.5 trixie (you confirmed), so the test matches production, and template 102 was never modified.

**Deviation 2: the suite cannot pin versions.** `download_server.js` takes the "stable" Fabric installer and resolves Fabric Loader and every mod as "latest" (R-12 confirmed by code, V). Setup was used only for the instance layout, unit, scripts and cron; jars were then installed from Modrinth by exact version number with hash verification. Loader 0.20.1 happened to be what the suite resolved.

**Deviation 3: linked clones.** The host had about 30 GB free, so both VMs are linked clones of the new template. VMs 100 and 101 were not touched (no trimming was needed).

## 2. Results by checklist item

| Item | Result | Label | Detail |
|---|---|---|---|
| §15.1 `save-all flush` log line | **Changed on 26.3** | V | Console: `[Server thread/INFO]: System chat: Saved the game`. Via RCON the log line is `System chat: [Rcon: Saved the game]` and the reply text still contains `Saved the game` (replies are concatenated without separator). The audit's `\]: Saved the game$` and the suite's `\]: Saved the (game\|world)` match neither. `Done (` startup line is unchanged |
| §15.2 save-off memory | Not measured | T | No busy world. Java RSS about 2.3 GiB per idle server (F-26 data point) |
| §15.3 SIGKILL in save-off window | **Partly holds** | V | `kill -9` of the main process: `ExecStopPost` re-enabled saving and removed the marker. `systemctl kill -s KILL` (the audit's command) kills the whole cgroup including the `ExecStopPost` helper: saving stayed off and the marker stayed (F-30) |
| §15.4 backup during export | Holds | V | Suite backup skipped ("Another operation ... skipping", wrapper exit 0, inner `backup.sh` exit 75). Lock owner is mislabelled "cleanup". Restore shares the same operation lock (I, not run) |
| §15.5 C2ME flush | Holds in this test | V/I | After `forceload` of 256 chunks and an immediate `save-off`, `save-all flush`, the region file held all 256 chunks as `minecraft:full`. A server start on the copy was not done, so a torn-write case is not excluded |
| §15.6 `/seed` match | Holds | V | Same value on survival, creative, and in the plots dimension |
| §15.7 plots dimension | Holds | V | `world/dimensions/fabricplots/plots/` exists after first boot (path no longer inferred). With the server stopped and `--force`, a hash of every file outside the three swapped folders was identical before and after the swap |
| §15.8 load errors | Holds | V | No `Failed to read chunk`, datafixer or corruption lines after the swap. Survival builds (gold floor, beacon, emerald structure, sign) are present on creative |
| §15.9 seam / parity | **Approximate only** | V | Section 4 |
| §15.10 sgui (X2) | **Resolved** | V | FabricPlots bundles `sgui 2.2.0+26.3` and `draftsmith 1.0.1+26.3` as nested jars. No separate sgui jar needed |
| §15.11 rrsync | Holds on trixie rsync 3.5.0 | V | Listing works. Refused: `ssh ... id`, interactive shell, writes ("sending to read-only server"), `..` paths, `-L`, a planted symlink to `/etc` ("unsafe arg"), wrong pinned host key. Accepted: `--delete-delay --partial-dir --timeout --bwlimit -rt`. Host fingerprint compared out of band before pinning |
| §15.12 CVE-2026-53783 | Fixed build installed | V/R | trixie ships 3.5.0+ds1-0+deb13u1 (the audit lists 3.5.0+ds1-0+deb13u1 as the fix). The CVE tracker itself was not re-read in this run (R) |
| §15.13 interrupted transfer | Holds | V | `iptables DROP` mid-pull: io timeout, `rc=12`, retry after restore sent only the remainder (about 21 s against about 36 s for the full 28 MiB at 800 KiB/s), creative kept running until the final swap. Resume from `.rsync-partial` per file is I from timing |
| §15.14 idempotent re-run | Holds | V | "already applied, nothing to do", exit 0, Java PID unchanged |
| §15.15 kill -9 mid-swap | **Partly holds; fixed by P3** | V | Kill between the two `mv` of one folder: recovered. Kill after `region/` but before `entities/`: server restarted with new `region/` and old `entities/` `poi/` (F-27). P3 fixes it |
| §15.16 space guard | Holds, with a side effect | V | Real full disk: exit 73, creative not restarted. But the previous rollback was already deleted (F-28) |
| §15.17 downtime | Measured | V | Stop to `Done` 17 s on this hardware (plus the configured warning delay). mc-router not tested |
| §15.18 / F-15 shrink guard | **Gap confirmed** | V | Section 3 |

## 3. New and updated findings

**F-27 (High, V). Partial-swap recovery leaves a mixed world.** `recover()` only restores a folder when the live folder is missing. A SIGKILL after `region/` is swapped but before `entities/` and `poi/` leaves new chunks with old entities and POI, the exact mismatch F-01 exists to avoid, and the server is then started on it. *Fix (P3):* if a rollback copy exists for a folder, move the live folder to `failed/recover/` and put the rollback back. Re-tested: consistent old state restored.

**F-28 (Medium, V). The rollback is deleted before the space check.** `rm -rf "$ROLLBACK"` runs before the `df` guard, so exit 73 leaves creative running but with no rollback. The claim "exit 73 without changing anything" (§15.16) is not true. *Fix:* check space first, delete the rollback only when the check passes, or compute need with the rollback still present.

**F-29 (Low, V). Silent exit when `latest.log` has no version line.** `version="$(grep ... | tail | awk ...)"` aborts the export under `set -eo pipefail` with rc=1 and no message. Add `|| true`.

**F-30 (Medium, V). `ExecStopPost` does not survive a cgroup-wide SIGKILL.** `systemctl kill -s KILL` kills the helper too. Real crash modes (OOM kill of the main process, `kill -9 PID`) are covered. Add a second line of defence: run `--ensure-save-on` at the start of every export, and have the doctor check flag a stale `.save-off-active`. The audit's §15.3 command should be `systemctl kill --kill-whom=main -s KILL`.

**F-31 (High, V). Suite confirmed-save is broken in screen mode on 26.3.** `server_control.sh:340` waits 120 s for a line that no longer exists and then proceeds unconfirmed ("Proceeding anyway"). RCON mode confirms through the reply and is fine. Impact: every backup on screen mode waits `SAVE_TIMEOUT_SECONDS` and runs without a confirmed flush. Needs the same pattern change as P2, ideally shared in one helper.

**F-15 (confirmed, V).** Survival was pointed at a fake world with one 8 KiB region file and a version line. Export published it (1 file, 8192 bytes). The pull replaced creative's 8-file, 8 MiB overworld region folder with it, restarted the server and logged success. Recovery needed a fresh export and `--force`. v1's `MIN_REGION_RATIO_PCT` guard still needs porting, plus a hard refusal when a dimension has zero `.mca`.

**F-09 / §5.5 (updated).** Section 4.

**X2 (resolved):** no separate sgui jar. **X3 (R):** CurseForge lists DimensionsCore (shown as 26.1.2, not confirmed for 26.3). Nothing found for Dimenager. The CurseForge "Multiverse" is an unrelated rifts mod, not Multiverse-Fabric. None are needed for the chosen design.

**X9 / Dimensional Inventories (partly resolved):**
- The audit's command is wrong: it is `/diminv pool <id> gameMode <mode>` (camelCase). `gamemode` gives "Incorrect argument".
- The default pool `default` (Nether, End) is `SURVIVAL`. On a creative server set it to `creative` too, or those dimensions are survival.
- Pools persist across restart in `world/dimensional-inventories/v2/config/main/dimension-pools.json`, outside the swap scope, so they survive swaps.
- `fabricplots.properties` defaults to `manage-gamemode=true`; set `false` as the audit says (applied and persisted; FabricPlots rewrites the file and leaves a `.bak`).
- **Not tested (T):** actual inventory and gamemode switching on dimension change, and `force-gamemode` behaviour. A mineflayer bot with `minecraft-data` 26.1 was rejected at handshake (`ECONNRESET`, no log line); no library supports protocol 777 yet.

**R-04 (updated):** lock paths in the blueprint match the suite (`backups/survival/.backup.lock`, `scripts/survival/.locks/operation_survival.lock`). Lock owner text is wrong, as predicted.

**Smaller notes (V):** the pull logs "server still running" while the server is stopped (cosmetic). `ssh -n` is needed when scripts pipe stdin. The suite's API wrapper requires Node 22 (Debian 13 ships 20); unrelated to the mirror. The suite's `main.sh --check` fails on a non-root user whose PATH lacks `/usr/sbin` (cron not found).

## 4. Seam and generation parity

Method: same seed, same version. Chunks were generated on both servers by `forceload` and compared block by block from the region files (custom reader for the 26.x format: palette entries are strings or `{id, properties}`, lists may be heterogeneous).

| Test | Pair | Chunks | Identical | Differing blocks |
|---|---|---|---|---|
| A, new chunks beside the mirror edge | C2ME / C2ME (same build) | 372 | 95 (26%) | 29,004 |
| C, same area | vanilla / vanilla | 324 | 118 to 151 (36 to 47%) | 8,364 to 12,497 |
| C, same area | C2ME / C2ME | 324 | 125 (39%) | 14,299 |
| C, same area | vanilla / C2ME | 324 | 78 to 108 (24 to 33%) | 26,119 to 30,661 |
| B, different area | vanilla creative / C2ME survival | 324 | 114 (35%) | 37,139 |

- Mirrored chunks match survival, apart from edge chunks that survival later changed by generating their neighbours (feature spill across chunk borders).
- Differences are local features: kelp and seagrass, ore-type blobs (andesite, granite, diorite), clay, moss, leaves and leaf litter. Terrain shape and biomes line up. No seam, corruption or datafixer error.
- **MC-55596 reproduces on 26.3 with no mods** (V). C2ME adds divergence on top: roughly three times the differing blocks of vanilla against vanilla. Pinning the same build narrows it only slightly (14k against 8k to 12k).
- Run-to-run variance exists (the same pair gave 8,364 and 12,497 blocks). Treat the table as indicative, not a benchmark.
- *Implication for §16.5:* remove C2ME from both servers if the mirror should look as close as possible. Keep it only if its performance matters more than feature-level identity.

## 5. Patches applied during the run

Source: the templates in [creative-mirror-sync-blueprint.md](creative-mirror-sync-blueprint.md) section 5, extracted unmodified first. Each was needed.

| ID | File | Change | Why |
|---|---|---|---|
| P1 | export, pull | `df -PB1 --output=avail` to `df -B1 --output=avail` | coreutils on trixie rejects `-P` with `--output`; both scripts exited rc=1 at the space check |
| P2 | export | `wait_log` pattern to `INFO[]]: (System chat: )?([[]Rcon: )?Saved the game[]]?[[:space:]]*$` | 26.3 log format (F-31). Still rejects a player typing the phrase (`<name> Saved the game`) |
| P3 | pull | `recover()` rolls back every folder that has a rollback copy | F-27 |

The unmodified export, run in screen mode on 26.3, timed out after 120 s and failed safe: saving re-enabled, marker removed, no snapshot published (V).

Not applied (still open): F-15 shrink guard, F-28 reordering, F-29 `|| true`, F-30 start-of-run recovery.

## 6. What the two-VM LAN test proves, and what it does not

**Proven by this setup (real SSH, rsync, rrsync, host key, LAN):** the whole export, transport, swap and recovery chain; rrsync restrictions on the shipped trixie build; host-key pinning with out-of-band fingerprint comparison; retry and resume after a network drop; idempotence and locking; swap isolation from the plot dimension; the 26.3 log and RCON behaviour; seed equality; generation parity.

**Still needs genuinely separate hosts or other conditions:**
- Cross-network path: WireGuard (F-12), MTU and latency effects, `from=` pinned to a tunnel address rather than a LAN address.
- Real bandwidth: `--bwlimit`, `RSYNC_TIMEOUT` and transfer time at production world sizes (here 28 MiB). Timer timing was not run (units were installed on survival only, started by hand).
- Save-off window length and memory on a busy world (§15.2); here the window was about 1 s, or 136 s only because it was artificially stretched.
- Player behaviour: pools, gamemode flapping, `force-gamemode`, read-only mirror via Leukocyte (not installed), the 60-second in-game warning with real players.
- mc-router and FabricProxy-Lite (not part of this test).
- Production disk, filesystem (reflinks) and I/O scheduler behaviour (F-18).

## 7. Required changes and next steps

1. Fix the templates in the blueprint: P1, P2, P3, then F-28, F-29, F-15 (with `--force` override and a zero-region refusal), and the F-30 start-of-run recovery.
2. Fix the suite's `server_control.sh:340` for 26.3 (F-31); add a test with the real 26.3 line formats (console and RCON) and a chat-spoof line.
3. Add an `ssh` shim and a Linux CI job with real rsync (R-09). Several of the defects here would have been caught by one execution.
4. Update the combined audit: §5.3 and F-19 (new log format), F-27 to F-31, §15 wording for items 3, 15 and 16, `/diminv ... gameMode` syntax and the pool `default` note, X2 and X3 resolutions.
5. Decide §16.5 (C2ME) with the parity numbers above; decide the shrink-guard threshold (§16.2).
6. Before production, re-run on genuinely separate hosts with a real client: pools and gamemode, a busy-world save-off window, WireGuard, and the real nightly timers.
7. Optional hardening seen along the way: drop the cgroup-wide kill concern by also checking stale markers in `doctor`; keep `mcsync` on `/bin/sh` as designed.

## 8. Cleanup (verified)

VMs 9101 and 9102 were stopped and destroyed with their disks and cloud-init volumes; the downloaded Debian image and all temp files on the host were removed; stale `known_hosts` entries were removed. The Debian 13 template was destroyed by mistake in that cleanup and then rebuilt and **kept** as VMID 9000 `debian13-template` (official cloud image, checksum verified, trixie fully upgraded, rsync 3.5.0, Java 25, guest agent, cloud-init user `dom` with the same key as template 102, 40 GB disk). `qm list` afterwards shows VMIDs 100, 101, 102, 200 and 9000. A few files under `/root` that predate this run (`scripts`, `tmp.sh`) were left alone.

## 9. Suite verification (added at your request)

Environment: a fresh linked clone (VMID 9201 `suite-test`) of the Debian 13 template, working tree copied in, run as the unprivileged user `mc` with passwordless sudo. Default Minecraft resolution (no pins): the suite chose 26.3 with Fabric Loader 0.20.1, Java 25 via Jabba (temurin 25.0.3), and 15 default mods. Scope: the suite's own tests, a Default-route install, and the lifecycle commands. The setup wizard's interactive Guided route (needs a terminal) and `migrate.sh` against a real older install were not run beyond their unit tests.

### 9.1 Change made: `--modpack` replaces `--vanilla`

Vanilla/Fabric is now the default; `--modpack` selects a CurseForge pack. Touched: `main.sh` (flag), `src/common/setup.sh` (dispatch and the CurseForge preflight, which now says "skipped" unless `--modpack`), `src/wizard/route.sh`, `package.json` (`setup:modpack`), `readme.md`, `CHANGELOG.md` (marked breaking), and three shell tests. Verified on Linux: shell tests for flags, main flow and the default route pass; `--check` skips the CurseForge section by default and reports it with `--modpack`; `--vanilla` now fails with "Unknown option"; `--modpack --dry-run` takes the modpack path (V).

### 9.2 The suite's own tests on Linux (V)

| Suite | Result |
|---|---|
| Node (`tests/js`) | 325 of 325 pass |
| Shell (36 files) | 1895 pass, 9 fail, 3 skip on the first run |

All 9 failures are independent of the flag change:

| Failures | Cause |
|---|---|
| 2 in `test_backup.sh` ("mirror is no longer writable by others", "folder inside the mirror is tightened") | Pass under `umask 022`, fail under Debian's default `umask 002` (directories created as 775 are not tightened). Either the code or the test assumes umask 022 |
| 2 in `test_run_backup.sh` ("failed daily is retried", "after the cap only hourly") | The test is day-dependent: on a Sunday the weekly tier is due first, so "Starting daily backup" never appears. Passes (53 of 53) with a weekday date |
| 5 in `test_migrate_api_server.sh` ("Everything is already up to date") | The `systemctl` test shim exits 0 for `list-unit-files`, so `migrate-lib/structure.sh` always decides to retire a web interface. Real systemd 257 exits 1 for a missing unit, so this is a shim defect. The existence check is also fragile on any systemd that exits 0 with "0 unit files listed" (not tested here) |

These suites were previously unverifiable on the Windows workstation (backup suites hang under Git Bash), so this is the first Linux run this audit knows of.

### 9.3 Default-route install and lifecycle (V unless noted)

| Area | Result |
|---|---|
| `main.sh --default --agree-eula --api-server` | Works: instance, systemd unit, hourly cron, server running, join hints. Version "latest" resolved to 26.3; `better-safe-bed` had no 26.3 build and was excluded automatically |
| `--check`, `manage.sh list/status/doctor` | Work. Doctor reports a fresh-install false FAIL ("backups folder does not exist") until the first backup |
| **Backup, stock config (screen mode)** | **Fails on 26.3.** `The server did not confirm the save` after 120 s, nothing archived (safe), doctor reports the failed backup. Same root cause as F-31 |
| Backup, RCON mode | Works: 1 s save-off window, verified archive, 163 KiB |
| Status player count | `unknown (the server did not answer /list)` without RCON; `0` with RCON |
| Restart / smart restart / stop / start | Work in RCON mode: player-aware, confirmed save, readiness check |
| Restore | Works: marker file returned, replaced files kept as `.pre-restore`. Refuses a running server (exit 3) and, without a terminal, requires `--file` and `--y` (by design) |
| Update check, `update-server`, mod add/remove/toggle | Work. `update-server` takes a pre-update backup first, reinstalls Fabric 0.20.1, keeps the valid server jar |
| Rollback from the update backup | Works: post-update marker gone, server restarted on restored files |
| API wrapper | Works with a valid key (`/health` open, other routes need the key, `/instances` lists the instance) on Node 20 despite its `engines: >=22` warning |

### 9.4 Suite defects found

| ID | Severity | Finding |
|---|---|---|
| S-1 | High | Screen-mode confirmed save never matches 26.3's log line, so every backup fails in the default (non-RCON) configuration. Fix the pattern (see P2 for a working one) and add a test with the real 26.3 lines. Until then the Default route should enable RCON or doctor should say so |
| S-2 | Medium | `--default --api-server` writes `API_SERVER.API_KEY=""` and `ENABLED=false`, yet deploys the wrapper. It crash-loops (restart counter 25) with "no API key configured" while setup printed "Listening on port 3030". Setup should refuse or generate a key |
| S-3 | Low | `update-mods.js` and `update-server.js` ignore `--help` and run for real (the latter started an update on `--help`) |
| S-4 | Low | Doctor false FAIL on a fresh install; status shows `unknown` players without RCON |
| S-5 | Low | The suite cannot pin the Fabric loader or mod versions (R-12), and the API wrapper's Node 22 requirement is not enforced by the installer on Debian 13 (Node 20) |
| S-6 | Low | Test defects in 9.2 (umask, Sunday, systemctl shim) |

Not changed: per your choice this section is report only; no suite code was changed other than the flag.
