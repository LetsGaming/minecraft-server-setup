# Creative mirror server: research audit

> **Status (2026-10-26):** the mirror described here is implemented; use [docs/mirror.md](../mirror.md) and `src/mirror/`. The script templates in this document were found to need fixes when they were run (see [2026-10-25-creative-mirror-vm-test-audit.md](2026-10-25-creative-mirror-vm-test-audit.md)); do not copy them.

Companion to [creative-mirror-blueprint.md](creative-mirror-blueprint.md). Researched 2026-10-23 from Modrinth API and pages, the Minecraft Wiki (26.1 and level format pages), the FabricPlots repository, and Fabric/Nucleoid Maven metadata. Nothing here was run against a live 26.3 server.

## Findings

| # | Finding | Evidence | Confidence |
| --- | --- | --- | --- |
| F1 | Latest stable game is 26.3; Fabric API 0.165.0+26.3 published 2026-10-23 | Modrinth API | High |
| F2 | 26.1 moved all dimensions to `dimensions/<ns>/<path>`; Overworld is `dimensions/minecraft/overworld`; players in `players/`; shared data in namespaced `data/<ns>/` | Minecraft Wiki 26.1 and level format | High |
| F3 | Seed and dimension settings moved from `level.dat` to `data/minecraft/world_gen_settings.dat` | Minecraft Wiki level format | High |
| F4 | FabricPlots 1.0.2+26.3 exists (2026-09-24), server-side, Fabric API only, bundles DraftSmith. The Modrinth description still says 26.1.2 and 26.2 only | Modrinth versions API vs page text | High that the file exists, medium that it is tested on 26.3 |
| F5 | Worlds: Multiverse 1.10.0+26.3, Multiworld 1.14.2 (beta, 26.3), Multiverse (senseiwells) 0.6.0+26.3 all list 26.3 | Modrinth API | High |
| F6 | Dimenager and DimensionsCore returned no 26.x results | Search | Medium (absence of evidence) |
| F7 | FabricPlots needs a fresh world because plot geometry bakes in at creation | FabricPlots README | High (author statement) |
| F8 | FabricPlots does not isolate inventories; Dimensional Inventories 2.2.2+26.3 can pool them | FabricPlots README, Modrinth API | High |
| F9 | `white-list` defaults to true since 26.3 snapshot 2 | Wiki server.properties history | High |
| F10 | sgui has `2.2.0+26.3` and `2.2.1+26.3` builds | Nucleoid Maven metadata | High |

## Design decision and rejected alternatives

| Option | Verdict | Reason |
| --- | --- | --- |
| A. Mirror = main world, plots = custom dimension (chosen) | Use | Sync touches three folders only; vanilla portals and seed behave as on survival. |
| B. Mirror copied into a custom dimension from a multi-world mod | Reject | Needs matching dimension type, noise settings and seed by hand; seams on mismatch; extra mod. |
| C. Sync the whole `world/` folder | Reject | Overwrites `world_gen_settings.dat`, so the plot dimension disappears; also overwrites creative player data. |
| D. Push from survival to creative | Reject | Survival would hold a credential for creative. Pull keeps survival read-only toward the network. |
| E. `save-off`, rsync straight from the live world over the network | Reject | Saving stays disabled for as long as the WAN transfer lasts; a dropped link risks leaving it off. |
| F. Snapshot to local stage on survival, then pull from stage (chosen) | Use | Save-off window is bounded to a local incremental copy, guarded by a trap. |

## Risks and open items

| ID | Risk | Severity | Mitigation or action |
| --- | --- | --- | --- |
| R1 | The plot dimension folder `dimensions/fabricplots/plots` is inferred from the dimension id `fabricplots:plots` plus the F2 layout, not observed | Medium | After first boot, run `find world/dimensions -maxdepth 2` and fix the blueprint tree if it differs. The sync never writes outside `dimensions/minecraft/*` either way. |
| R2 | Survival mods or datapacks that alter worldgen, or a different MC patch version, make fresh chunks on creative differ from survival | Medium | Keep mod and datapack sets and the game version identical for worldgen-relevant parts. Upgrade both VMs together. |
| R3 | FabricPlots requirements text lists sgui for 26.1.2 and 26.2 only; the 26.3 jar's sgui need is unconfirmed | Low | Start the server without sgui first; if it reports a missing dependency, add `sgui-2.2.1+26.3.jar`. |
| R4 | The 26.3 jar and FabricPlots 26.3 support are new (one month old) and the page text is stale | Low | Test on a throwaway creative VM snapshot before production. |
| R5 | `Saved the game` log pattern assumed from vanilla `save-all` output | Low | Verify once with `grep -n 'Saved the game' logs/latest.log` after a manual `save-all flush`. |
| R6 | Entities, poi and dragon-fight data are inside the synced dimension directories; a half-synced state would mismatch them with region files | Low | Dimension folders are copied as a unit while creative is stopped, after a verified full pull. |
| R7 | `rrsync` path and presence differ across Debian releases | Low | `command -v rrsync`; fallback is `/usr/share/doc/rsync/scripts/rrsync.gz`. |
| R8 | A world border, spawn, or gamerule changed on survival does not propagate (those live in non-synced `level.dat` and `data/`) | Info | Intentional. Set these once on creative. |
| R9 | Survival players' builds appear on creative, but the creative server is not a backup of survival | Info | Keep the normal backup system for survival. |
| R10 | Sync is a mirror with `--delete`: griefing on survival is mirrored 24 hours later | Info | Acceptable by design; creative is disposable. Do not use it for restores. |

## Not verified

- Behaviour of Worlds: Multiverse and Multiworld on disk for non-vanilla worlds beyond what Multiworld's page states (`dimensions/<id>/<path>`).
- Whether the existing backup staging mirror in this repo can serve as the `STAGE` source (not checked, per instruction to skip existing research).
- Actual `ionice`, `bwlimit` and timing numbers: no benchmark was run. Tune `BWLIMIT_KBPS`, `COPY_TIMEOUT` after the first full pull.
- All scripts are untested on Debian. They passed no `shellcheck` run; run `shellcheck` and a dry run before enabling the timer.

## Sources

- [Fabric API 0.165.0+26.3 (Modrinth)](https://modrinth.com/mod/fabric-api/version/0.165.0+26.3)
- [FabricPlots (Modrinth)](https://modrinth.com/mod/fabricplots) and [repository](https://github.com/beachfury/fabricplots)
- [Worlds: Multiverse for Fabric](https://modrinth.com/project/rDdf0tz6)
- [Multiworld](https://modrinth.com/project/fgvoNDL1)
- [Multiverse (senseiwells)](https://modrinth.com/mod/multiverse-dimensions)
- [Dimensional Inventories](https://modrinth.com/mod/dimensional-inventories)
- [Java Edition level format](https://minecraft.wiki/w/Java_Edition_level_format) and [Java Edition 26.1](https://minecraft.wiki/w/Java_Edition_26.1)
- [server.properties history](https://minecraft.wiki/w/Server.properties)
- [sgui builds (Nucleoid Maven)](https://maven.nucleoid.xyz/eu/pb4/sgui/)
