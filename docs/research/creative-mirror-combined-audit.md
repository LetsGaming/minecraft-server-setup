# Creative mirror server: combined research audit

> **Status (2026-10-26):** the mirror described here is implemented; use [docs/mirror.md](../mirror.md) and `src/mirror/`. The script templates in this document were found to need fixes when they were run (see [2026-10-25-creative-mirror-vm-test-audit.md](2026-10-25-creative-mirror-vm-test-audit.md)); do not copy them.

Date: 2026-10-24. Status: research and design only. Nothing in this document or its sources has been run against a live Minecraft 26.3 server, a Debian VM or a real SSH link.

This document merges five research documents and the original brief into one audit. It removes duplication and resolves contradictions between them, but keeps every finding whose loss would make the design misleading. The full script templates are **not** copied here; they live in [creative-mirror-sync-blueprint.md](creative-mirror-sync-blueprint.md) section 5.

## 0. How to read this

### 0.1 Sources merged

| Short name | File | Date | Role |
|---|---|---|---|
| Brief | `MIRROR_RESEARCH_TASK.md` (outside the repo) | | The task: a creative VM mirroring the survival seed/world plus a flat plot world, refreshed every 24 h over SSH/rsync, with a mod stack, directory layout, sync workflow and a Bash template as deliverables |
| Multiworld research | [mirror-servers-multiworld.md](mirror-servers-multiworld.md) | 2026-10-20 | Broad, suite-wide research on mirror servers and multi-world support (single host, no plan). Source of the seed-determinism, C2ME, vanilla-limits and player-transfer findings |
| v1 blueprint / v1 audit | [creative-mirror-blueprint.md](creative-mirror-blueprint.md), [creative-mirror-audit.md](creative-mirror-audit.md) | 2026-10-23 | First answer to the brief. **Superseded** by v2, but several of its ideas and its known defects are recorded in section 9 |
| v2 blueprint / v2 audit | [creative-mirror-sync-blueprint.md](creative-mirror-sync-blueprint.md), [creative-mirror-sync-audit.md](creative-mirror-sync-audit.md) | 2026-10-24 | Second, deeper answer to the brief. **Canonical design and script templates** |

The brief told each researcher to ignore existing research, which is why v1 and v2 overlap and sometimes disagree. Where they disagree, this audit says which statement wins and why (section 2).

### 0.2 Evidence labels

| Label | Meaning |
|---|---|
| **V** | Verified against a cited primary source (Mojang manifest, Fabric meta, Modrinth API, mod repository or README text, man pages, Debian trackers, minecraft.wiki as the community mirror of Mojang changelogs) on the date of the source document |
| **R** | Reported: secondary, a README promise about behavior, a forum post, or wiki text read through a summarizing fetcher. A README promise about mod **behavior** is never V, only R |
| **I** | Inferred by the researcher from V facts or reasoning |
| **T** | Must be tested on the target servers before relying on it |
| **C** | Found while combining the sources for this audit (comparison of v1 and v2, or a fact in one source contradicting a claim in another). Treat like I |

All version numbers are time-bound. The three research dates span four days and some versions moved in that time (section 3.1).

## 1. Brief requirements and where they are answered

| Brief item | Verdict | Where |
|---|---|---|
| Fabric 26.3 dimension/world manager mods (the brief names *Worlds: Multiverse for Fabric*, *Dimenager*, *DimensionsCore*) | Worlds exists for 26.3. **Dimenager and DimensionsCore have no Modrinth project at all.** No world manager is needed for the recommended design | 6.1, 7 |
| Host a survival-seed replica and a flat plot world as separate dimensions in one instance | Yes: the mirror is the creative server's **own overworld** (created with the survival seed), the plot world is FabricPlots' `fabricplots:plots` dimension | 7 |
| Plot mod (brief names *FabricPlots* or a flat preset) | FabricPlots 1.0.2+26.3 is the only grid-plot mod on 26.3 | 6.2 |
| Multi-dimension storage under `world/dimensions/...` | 26.1+ layout documented; plot dimension path is inferred, not observed | 4, 10.1 |
| Pre-flush with `save-all flush` via screen/RCON | Yes, plus `save-off`/`save-on` handling with marker, trap and `ExecStopPost` recovery; or no extra flush at all by reusing the repo's backup staging mirror | 10.2, F-02 |
| Transfer `r.*.*.mca` with rsync over SSH | Yes; only `region/`, `entities/`, `poi/` region files | 10.3 |
| Stop creative **or invoke a dimension reload**, replace only the seed dimension, restart | **A runtime dimension reload does not exist** in any 26.3 mod; the creative server must stop. Downtime is reduced to a rename swap | F-01, 10.5 |
| Isolation: overwrite only the seed dimension, never the plot dimension | Four independent isolation layers | 10.4 |
| Passwordless ed25519 SSH between the VMs | Yes, pull model, dedicated read-only `rrsync` account | 11 |
| systemd timer + Bash script with screen and rsync | Yes, two timers (export on survival, pull on creative) | 12 |
| Logging, unreachable hosts, interrupted transfers, disk space | Error matrix, retries, resumable partials, `df` preflights | 12.3 |
| Survival must never be corrupted, locked indefinitely or slowed | Transfer only from an immutable local snapshot; save-off bounded by timeout and repaired after SIGKILL; pull throttled with `--bwlimit` | F-02, F-08, F-14 |

## 2. Contradictions between sources and how they are resolved

| # | Topic | Statements | Resolution |
|---|---|---|---|
| X1 | Fabric API / Loader version | Multiworld research (10-20): Fabric API 0.164.0+26.3, Loader 0.19.5. v1/v2 (10-23/24): Fabric API 0.165.0+26.3 (published 2026-10-23), Loader 0.20.1 (2026-10-19) | Not a contradiction: releases between the research dates. Use the newest and re-check at install time |
| X2 | Does FabricPlots need sgui? | v1: FabricPlots lists sgui as required; sgui is not on Modrinth (Nucleoid Maven has `2.2.0+26.3` and `2.2.1+26.3`); the requirement text names only 26.1.2 and 26.2, so the 26.3 jar's need is unconfirmed (v1 R3). v2: "Bundles sgui" | **Unresolved (T).** v1 also states FabricPlots bundles DraftSmith 1.0.1. Start the server without a separate sgui jar first; add `sgui-2.2.1+26.3.jar` only if it reports a missing dependency |
| X3 | Do Dimenager and DimensionsCore exist? | v1: no 26.x search results, medium confidence (absence of evidence). v2: no Modrinth project (HTTP 404) and not found with the 26.3 facet; Multiverse-Fabric also 404 | v2 is stronger evidence. **CurseForge was never checked** by any source |
| X4 | Is there a maintained world-sync tool for 26.x? | Multiworld research: "no maintained tool exists for 26.x"; the only one found, Mirage Sync, is 1.21.11 only. v2: **RegionCast 1.0.2+26.3** exists, purpose-built for mirroring | v2 found a 26.3 tool the earlier search missed (or it was published after 10-20; not established). RegionCast is still not usable cross-host (6.4) |
| X5 | FabricProxy-Lite on 26.3 | v2: "not verified for 26.3". Multiworld research: 2.12.0 (2026-03-28) lists 26.1 to 26.3 on Modrinth (V) | Listed for 26.3 per Modrinth (V); actual behavior with mc-router PROXY protocol on 26.3 is still T |
| X6 | Which dimensions are mirrored | v1: all three (`overworld`, `the_nether`, `the_end`). v2: overworld only by default; nether/end opt-in via `MIRROR_DIMS` | v2 is canonical. Mirroring the End has a specific data-mismatch risk (F-21) |
| X7 | What is copied inside a dimension | v1: the **whole** dimension folder, including its `data/` (raids, chunk tickets, world border, `ender_dragon_fight.dat`). v2: only `region/`, `entities/`, `poi/`; the dimension's `data/` stays creative's own | v2 is canonical. Consequence for v1's claim R8: see X8 |
| X8 | Does a world-border change on survival propagate? | v1 R8: no, because border, spawn and game rules "live in non-synced `level.dat` and `data/`" | **v1 R8 is wrong for v1's own design (C).** Since 26.x the world border is stored per dimension in `dimensions/<ns>/<dim>/data/minecraft/world_border.dat` (V, multiworld research and v2 F-04), so v1's whole-folder copy **would** carry it. Under v2 (chunk folders only) the border does not propagate. Spawn (`level.dat`) and game rules (`data/minecraft/game_rules.dat`) do not propagate in either design |
| X9 | `force-gamemode` on creative | v1: `force-gamemode=true`, `difficulty=peaceful`. v2: `force-gamemode=false` because Dimensional Inventories owns gamemode per pool. Multiworld research: `force-gamemode=true` for a creative **separate instance without mods** | Not a contradiction once the stack is known: with Dimensional Inventories use `false` (two mechanisms fighting over gamemode cause flapping on dimension change, which is also why FabricPlots gets `manage-gamemode=false`); without it, `true` |
| X10 | Hard links | v1: "Hard links are not a safe shortcut because Minecraft rewrites region files in place." v2: export snapshots use `rsync --link-dest` hard links | Both true, different objects. Never hard-link **the live world** (or the backup staging mirror) into a snapshot. v2 hard-links **between export snapshots**, whose inodes the live server never opens, so in-place rewrites cannot reach them |
| X11 | ShellCheck status | v1 audit: scripts "passed no `shellcheck` run". v2 audit: v2 templates pass `bash -n` and ShellCheck 0.11 (`-S style`, repo `.shellcheckrc`) | Applies to different scripts. v1 scripts are unlinted; v2 scripts are lint-clean but **unexecuted** (the workstation had no rsync, WSL or Docker) |
| X12 | Mod for "periodic sync" vs repo-native | Multiworld research favoured "refresh from the suite's backup archive while the mirror is stopped" | v2 generalises this as `SOURCE_MODE=stage` (copy from the backup staging mirror, not the archive) |
| X13 | mc-router | Multiworld research listed mc-router under "Docker-first routers ruled out for the proxy role" (suite-wide constraints) | The brief makes mc-router given infrastructure at the edge. v2 shows it running as a plain binary with flags or a routes JSON, so no Docker is implied. Its role is hostname routing to two VMs, not a Velocity-style proxy |

## 3. Executive summary

- **Platform:** Minecraft 26.3 "Wilderness Bound" is the current stable release (2026-09-15, DataVersion 5023). Fabric 26.3 is well supported; Java 25 is required since 26.1. V
- **Mirror location:** make the survival replica the creative server's **own `minecraft:overworld`**, created fresh with the survival seed, not a second dimension. No world manager mod is needed. Reasons: no 26.3 mod can reload a dimension from disk at runtime, so any mirror needs a stop anyway (F-01); dimension ids stay identical to survival, so villager memories (GlobalPos), lodestone compasses, portal links, `/seed`, spawn and the dragon fight behave as on survival; a custom-dimension copy needs dimension type, noise settings and seed matched by hand, and one mismatch gives seams. I/V
- **Plot world:** FabricPlots 1.0.2+26.3, which ships its own flat `fabricplots:plots` dimension. Dimensional Inventories separates mirror and plot inventories. V
- **The 26.1 storage change is the biggest trap:** every dimension now lives under `world/dimensions/<ns>/<path>/`; the seed moved to `data/minecraft/world_gen_settings.dat`. Older tutorials that copy `world/region` or `DIM-1` silently copy nothing, and syncing the whole world folder would delete the plot dimension (F-04, F-05). V
- **"Identical terrain" is only approximate.** Already-generated chunks are copied exactly, but chunks generated later on creative can differ in local features even with the same seed and version (Mojira MC-55596, generation-order dependent), and any version, datapack or worldgen-mod difference makes larger differences (section 5). R/I
- **Safety model (v2):** survival writes an immutable local snapshot (one short `save-off` window, or none by reusing the backup staging mirror); creative pulls it with a read-only `rrsync` key in a dedicated account; creative downtime is a rename swap of pre-staged folders; every failure path leaves creative on its previous data and survival saving.
- **Security:** Debian bookworm's rsync 3.2.7-1+deb12u6 is listed vulnerable to **CVE-2026-53783** (rrsync restricted-directory escape); fixed in rsync 3.5.0 and in trixie-security only (F-03). V
- **Ecosystem maturity is the main dependency risk:** FabricPlots is three months old with one developer; all world managers are young (F-09). The recommended design depends only on FabricPlots (plots) and vanilla behavior (mirror).
- **Status:** the v2 scripts are lint-clean and untested. The verification checklist (section 15) must pass on staging copies before production.

## 4. World format on 26.1 through 26.3

26.1 restructured the whole save (snapshot 26.1-snap6); 26.2 and 26.3 kept it. The old layout (root `region/`, `DIM-1`, `DIM1`, `playerdata`, `stats`, `advancements`) does not apply from 26.1. V (minecraft.wiki level format and 26.1 changelog)

```
<level-name>/
  level.dat (+ _old, _new), session.lock
  players/{data,stats,advancements}/<uuid>.*
  data/minecraft/{game_rules,world_gen_settings,weather,world_clocks,scoreboard,...}.dat, maps/<n>.dat
  dimensions/minecraft/{overworld,the_nether,the_end}/{region,entities,poi,data/minecraft/...}
  dimensions/<namespace>/<path>/          custom dimensions (path form: see below)
  datapacks/, resourcepacks/, generated/
```

| Fact | Label |
|---|---|
| The **seed is no longer in `level.dat`**. `WorldGenSettings` (seed, `generate_structures`, the registered dimension set, bonus chest) moved to `data/minecraft/world_gen_settings.dat`. Any "edit `level.dat`" or "read the seed from `level.dat`" advice is wrong on 26.1+ | V |
| Game rules moved to `data/minecraft/game_rules.dat`; 26.1 turned all game rules into a registry with snake_case ids | V |
| `level.dat` still holds `GameType` (default gamemode int), `difficulty_settings` (difficulty is a string), `DataPacks`, `spawn{dimension,pos,...}`, `DataVersion`, `enabled_features`, `WasModded`, `ServerBrands`, and `version_history` (added in 26.3 snapshot 7) | V |
| Per-dimension data lives in `dimensions/<ns>/<dim>/data/minecraft/`: `raids.dat`, `chunk_tickets.dat`, `world_border.dat`; the End adds `ender_dragon_fight.dat` | V |
| Maps are global (`data/minecraft/maps/<n>.dat`); map ids are world-wide | V |
| Custom dimension folder: `dimensions/<namespace>/<path>/`. Stated by Multiverse's README and Multiworld's page for their own dimensions (V for those mods); for vanilla datapack dimensions and for FabricPlots it is inferred | I |
| `session.lock` holds one character and an OS lock; a second process on the same directory aborts | V |
| `ops.json`, `whitelist.json`, bans, `server.properties`, `usercache.json`, `eula.txt` live in the server working directory, not in the world, so a world copy does not carry them | V/I |
| Upgrade from 1.21.x to 26.1 is an automatic one-way conversion on first load; a 26.1+ world cannot be opened by 1.21.x at all. 26.3 reports world-upgrade progress at startup through the management protocol (`world/upgrade_*` notifications) | V |
| Chunk NBT carries no seed or world UUID, so `region/`, `entities/`, `poi/` can move between worlds | I (chunk format lists no such tag) |
| `poi/` is rebuilt from chunk data when sections load, but copying it avoids a rebuild | I |

**Consequence for the mirror:** `world_gen_settings.dat` must never be synced. It carries the seed **and** the registered dimension set; overwriting it from survival would drop `fabricplots:plots` from the creative world. FabricPlots also bakes plot geometry in at world creation (README: use a fresh world the first time), so the creative world must be **created fresh with FabricPlots installed and the survival seed set**, after which only chunk folders are replaced.

## 5. Vanilla capabilities, limits and terrain equality

### 5.1 One process, one save

- One server process = one save (`level-name`), one `server.properties`, one default gamemode, one difficulty, one hardcore flag, one set of game rules, one set of player data, one seed. Many dimensions can live in that save. V
- No per-dimension game rules, gamemode, difficulty or seed exist in 26.1 to 26.3 (not found; absence is not proof). I
- Creative is a server-wide default in vanilla, not a per-world property. `gamemode` is the default for players without saved data; `force-gamemode=true` resets every player to it on join. Per-player mode is stored in `players/data/<uuid>.dat` (`playerGameType`). V/R
- 26.2: "As the host of a world, changing the game mode with F3+F4 or with commands now changes the default game mode of the world." Whether this applies to dedicated servers, and whether a dedicated server rewrites `level.dat` `GameType` from `server.properties` on start, is **not established** (T).
- `level-seed`, `level-type`, `generator-settings`, `generate-structures`, `hardcore` and `initial-*-packs` apply **only at world creation**. Setting `level-seed` after the creative world exists does nothing (I for seed/type, V for hardcore/packs wording). `level-type` values: `minecraft:normal`, `flat`, `large_biomes`, `amplified`, `single_biome_surface`; whether `minecraft:flat_all_dimensions` (26.2, hidden in the create screen) is accepted is open.
- 26.3 `server.properties` defaults: `white-list=true` (since 26.3 snapshot 2), `pause-when-empty-seconds=60`, `accepts-transfers=false`, `server-port=25565`, `rcon.port=25575`, `management-server-port=0`, `spawn-protection=16`, `gamemode=survival`, `force-gamemode=false`. A fresh creative server therefore **rejects players until the whitelist is filled** or `white-list` is set deliberately. V
- 1.21.9 removed `pvp`, `spawn-monsters`, `allow-nether`, `enable-command-block` from `server.properties`; they are game rules now. V
- Spawn protection: ops bypass it; disabled when the server has no ops. The wiki's "Overworld only" predates `spawn.dimension` in 26.x and is unverified for 26.x. V/I

### 5.2 Datapack dimensions

- Definition `data/<ns>/dimension/<name>.json` (singular, unchanged) with `type` and `generator` (`noise`, `flat`, `debug`). The 26.x `dimension_type` schema changed (`attributes`, `default_clock`, `timelines`; 26.1 added `default_clock` and `has_ender_dragon_fight`), so reference an existing type such as `minecraft:overworld`. Flat generator JSON matches vanilla 26.3 `world_preset/flat.json` (`minecraft:flat` with `layers`, `biome`, `features`, `lakes`, `structure_overrides`). A Java "void" is a flat generator with air layers. V/I
- **A datapack dimension cannot have its own seed** (22w11a removed the `seed` field; all dimensions use the level seed). That rules out "a second overworld-like dimension with the survival seed" unless the creative level seed already equals the survival seed, or Panda Per-World-Seed overrides it. V
- Added only on world open / full restart; worldgen files are not applied by `/reload`. Vanilla portals only lead to the three vanilla dimensions. Removing and re-adding a dimension can lose registration data (MC-215960 and related, R). Datapack format: 107.1 in 26.2, 121 in 26.3; a 26.2 pack may not load on 26.3. V/R/I

### 5.3 Save commands and copy safety

- `save-off` "disables the server writing to the level files (**except player, advancement, stat files**)"; changes queue in memory. A mirror must therefore exclude `players/**` (both designs do). V
- While saving is off, chunks are not unloaded (they could not be saved), so memory grows for the length of the window (PaperMC#10657, SPIGOT-6383). V
- `save-all flush` writes all chunks immediately and **freezes the server briefly**; length scales with dirty chunks. V/I
- Copying without `save-off` + confirmed flush gives torn region files and `entities/`/`poi/` out of sync with `region/`. I
- **26.3 changelog:** "Some log lines that server software might look out for have been removed. The Minecraft Server Management Protocol can be used instead." Which lines is unknown. The screen-mode "confirmed save" depends on the `Saved the game` log line, so this must be tested on 26.3 (T). The 26.1 language file still has the strings "Automatic saving is now disabled", "Saving the game (this may take a moment!)", "Saved the game", "Unable to save the game (is there enough disk space?)" (V for the lang file, not for 26.3 log output).
- A world opened by an **older** server than the one that wrote it is unsupported (DataFixerUpper upgrades are one-way). V
- On Fabric, removing a mod gives no warning; unknown blocks become air and unknown entities are dropped. Adding mods to the creative copy is safe; mods that place blocks on survival must also be on creative. R

### 5.4 Seed determinism: how far "same terrain" goes

- Mirrored chunks are copied byte-for-byte, so they match exactly. Everything below is about chunks **generated later on creative** (outside the mirrored area), which is what the "seam" check depends on.
- The same seed generates different new terrain when the generator changes between versions. Recent changes: 26.2 added sulfur caves; 26.3 added the dappled forest biome, abandoned camps, fallen trees and a large worldgen datapack refactor. **Both servers must run the exact same Minecraft patch version.** V/I
- Must also match: world preset (`level-type`, `generator-settings`), `generate-structures`, worldgen datapacks, `enabled_features`, worldgen-changing mods (e.g. Terralith 2.6.5+26.3, which its README says cannot be removed from or safely added to an existing world; William Wythers' Overhauled Overworld 3.0.1). V/I
- Fabric Loader + Fabric API alone should not change terrain; biomes change only when a mod calls the Biome API. R (1.21.8 javadoc), I for 26.x
- **Vanilla generation is not fully deterministic:** Mojira MC-55596 (unresolved, reported 1.7.9 through 1.20.1; Overworld and Nether, none known in the End) says some chunk features vary with chunk generation order. C2ME's README cites it: "worlds will vary significantly run-to-run even with the same seed." Whether it reproduces on 26.x is untested. Consequence: **block-for-block identity of newly generated chunks cannot be promised even without mods**; biomes, large terrain and structure positions are far more stable than vegetation and small features. R/I
- Chunks outside the mirrored area generate with creative's seed; a different seed gives hard seams because `blending_data` only blends old-version chunks. I

### 5.5 C2ME (`c2me-fabric`), a suite default with mirror impact

The suite's `performance_mods.txt` installs `c2me-fabric` by default (`PERFORMANCE_MODS` defaults to true). V

- **Every build is typed alpha** (`0.4.x-alpha.0.N`), a new one appears every few days, and the suite's version picker falls back to the newest alpha when no release exists. Survival and creative set up at different times will run **different C2ME builds** (I). Only the latest Minecraft release and snapshot are fully supported. V
- It rewrites chunk scheduling, I/O (async serializer, NBT cache) and parts of worldgen (`opts-dfc` density-function compiler, `opts-natives-math` native SIMD noise, replaced random sources, aquifer/structure-weight optimizations, biome cache). README claims no change to vanilla generation **by default** (R); no published test of bit-identical output was found. V for modules, R for behavior.
- `chunkSystem.recoverFromErrors` (off by default) "will cause errored chunk to be regenerated entirely, which may cause data loss". V (source text)
- Issue search for "corrupt world" returned 10 closed issues (e.g. #580 corruption with a modpack, fixed by disabling seven options; #568 world creation hangs with the OpenCL module). R
- **Open for the mirror:** whether `save-all flush` also flushes C2ME's async serializer (if not, a `save-off` copy may be inconsistent), and whether C2ME vs no C2ME, or two C2ME builds, generate identically. Pin the same C2ME build on both servers or remove it from both (T, section 15).

## 6. Fabric 26.3 mod landscape

### 6.1 Dimension / world managers (not needed for the recommended design)

| Mod (Modrinth slug) | 26.3 build | Maturity | Side, license | Create | Seed per world | Flat | On-disk location | Runtime unload/reload |
|---|---|---|---|---|---|---|---|---|
| Worlds: Multiverse for Fabric (`mc-worlds`, Wroud) | 1.10.0+26.3 (2026-10-07) | 17.6k downloads, 1 star, one developer, about 40 releases in 13 months (fast churn) | server, client optional; MIT | `/worlds create <id> [seed]`, `from-preset minecraft:flat` | yes | yes | `dimensions/minecraft/<id>` (I) | Auto-unload 1 min after last player; **no reload-from-disk**. Per-world game rules, time, weather; keeps stored generators it cannot decode |
| World Manager (`melius-worldmanager`, DrexHD) | 1.5.1+26.3 (2026-09-24) | 15k downloads, 9 stars | server only; MIT | `/wm create <id>` (GUI), `/wm create <id> <path>` imports a world folder | yes | yes (GUI) | Fantasy persistent level (I) | Delete only; no per-world rules listed |
| Multiworld (`multiworld`, IsaiahMC) | 1.14.2 **beta** for 26.2/26.3 (2026-10-09) | 84k downloads, **117 open issues**; README lists delete as both present and "coming soon" | server, client optional; LGPL-3.0+ | `/mw create <id> NORMAL -g=FLAT -s=<seed>` | yes | yes | `world/dimensions/<id>/<path>` (V) | load/unload "coming soon"; uses Fantasy; per-world gamerule/difficulty (R) |
| Multiverse (`multiverse-dimensions`, senseiwells) | 0.6.0+26.3 (2026-09-15) | 0.x, 6.8k downloads | server only; MIT; **needs Fabric Language Kotlin** | `/multiverse create from <type> <id> <seed?>` | yes | `multiverse:flat` | `world/dimensions/<ns>/<path>/` (V) | `clone` copies region files but its README warns it "may hang your server"; per-dimension game rules and tick rate; whether a clone keeps the seed is open |
| Custom Dimensions (`custom-dimensions`) | 1.3.1 | | server only; All rights reserved | `/dimension create`, restart required | no | no | datapack | no |
| Fantasy (NucleoidMC library) | v0.8.4+26.3 | 149 stars | library | API | yes | void generator | | create/unload/delete at runtime; persistent levels must be re-opened by the consuming mod at startup (V) |
| World Portal / Dimension Link (mahmudindev) | 26.3 | | ARR | Redirect portals only; cannot create dimensions | | | | |

- **No 26.3 build** (newest 1.21.11 or older): Quantum, Into the Multiverse, Superflat/Flat Dimensions, Multiworld Inventories, MultiWorld Positions, WorldEngine, Seeded Dimensions, Creativerse, PrivateCreative, GMPerms, Universal Perms. V
- **Do not exist on Modrinth:** Dimenager, DimensionsCore, Multiverse-Fabric, PlotSquared for Fabric. CurseForge not checked. V
- Removal behavior of **every** runtime-world mod is not established (T). Each mod lags Minecraft releases (observed: Multiworld about 6 weeks after 26.1, Multiverse about 2 months for 26.1.2); a lagging mod strands the server on the old version or forces removal.

### 6.2 Plots, protection, inventories, permissions

| Mod | 26.3 build | Notes | Label |
|---|---|---|---|
| **FabricPlots** (`fabricplots`, beachfury) | 1.0.2+26.3 (2026-09-24), MIT, server only | Flat dimension `fabricplots:plots` with road grid; `/plot claim/auto/home/visit/menu/world/admin`, trust/deny, merging, per-player claim limits, fixed toggles (PvP, biome, mob spawns), inactivity expiry, bundled build tool jailed to the plot (DraftSmith). Forces creative inside / survival outside unless `manage-gamemode=false`. **Does not isolate inventories.** Plot geometry fixed in code; fresh world required first time. Created 2026-06-27, 889 downloads, 3 stars, 5 open issues, one developer. Modrinth description still says "26.1.2 & 26.2"; GitHub releases lag Modrinth; sgui need unclear (X2) | V (file exists), R (behavior) |
| PlotSquared | no Fabric port | No generic per-plot flag system exists on Fabric | V |
| Flan, GOML ReServed, Open Parties and Claims, Claims | 26.3 builds | Area/chunk claims inside an existing world, **not a plot grid**. OPaC 0.33.0 beta (102 open issues); Flan 1.12.8.b ARR; GOML 1.22.0 rc-1 needs Polymer | V/R |
| **Dimensional Inventories** (`dimensional-inventories`, Thomilist) | 2.2.2+26.3 (2026-09-16), MIT, server only | Dimension pools share inventory, ender chest, XP, health and **gamemode**; leaving a pool saves and clears the inventory and loads the destination's. **Entities crossing pools are deleted.** Advancements/stats switchable per pool. No difficulty or game rules. Built for "a separate creative world on a survival server". 12.9k downloads, 36 versions since 2023, releases 2 to 8 weeks after each MC release. Per-pool files stay on disk after removal (I) | V/R |
| Leukocyte (`leukocyte`) | 0.4.1+26.3, LGPL-3.0 | Dimension-wide rule authorities (`break`, `place`, `interact_blocks`, `pvp`, `portals`, ...): can make the mirror read-only | V |
| LuckPerms | v5.5.85-fabric | Lists 26.3; mixed-loader listing, pick the Fabric file | V |
| Panda Per-World-Seed (`pandaperworldseed`) | 1.2.0+26.3, CC0 | Per-dimension seed override in `config/per_world_seed.json`; fallback for an existing creative world with the wrong seed | V |
| Lithium, FerriteCore | check per release | Optional performance; Lithium's effect on generation was not examined | |

### 6.3 Moving players between servers (optional)

- mc-router hostnames are the brief's routing method (section 13). Plain alternative: two server-list entries.
- Vanilla `/transfer <host> [port] [players]` (1.20.5+): permission level 3, dedicated servers only; target needs `accepts-transfers=true` (default false); command blocks and functions run at level 2 so they cannot call it; no state moves; client prompt and refusal text unverified. 26.4 snapshots add a `properties` map. V/I
- Velocity 4.3.0 + FabricProxy-Lite 2.12.0: a second JVM, shared secret, backends bound to localhost/firewalled (an `online-mode=false` backend reachable directly allows impersonation), two version couplings per MC bump, chat-signing kicks as a documented failure mode. Heavy for this setup. V
- The Minecraft Server Management Protocol (JSON-RPC over WebSocket, 1.21.9+, 3.1.0 in 26.3, disabled by default, 40-char secret, TLS default on) covers allowlist, ops, bans, kick, game rules, settings, `save`, `stop`, and in 26.3 world-upgrade notifications. Candidate replacement for screen/RCON log scraping. V

### 6.4 Existing mirror/sync tools

| Tool | State | Verdict |
|---|---|---|
| **RegionCast** (`regioncast`) 1.0.2+26.3, MIT, 83 downloads | Pulls changed region files from a source world while the **destination is stopped**, sends `save-off`/`save-all flush` to the source over RCON, keeps 3 undo steps | Needs filesystem access to **both** worlds (a cross-host mount), documents only dimensions -1/0/1; 26.x path handling not checked. Not production-ready cross-host. V/I |
| Mirage Sync (`mirage-sync`) | MC 1.21.11 only, 1.2.0 (2026-04-25), 172 downloads, build from source. README (R): Netty port + shared token, SHA-256 per `.mca`, kicks players, force-saves, unloads chunks, swaps files | Not usable on 26.x |
| ChunkSync, Creativerse | 1.21.11; intra-world only | Not cross-server |
| Ledger 1.3.25 | 26.3; logs and rolls back block changes | Nothing replays its log elsewhere |

**Live or near-live mirroring between servers does not exist for current versions.** The nightly design is periodic by necessity.

## 7. Architecture options and decision

| Option | Source | Verdict | Reason |
|---|---|---|---|
| **Mirror = creative's own `minecraft:overworld` (survival seed), plots = FabricPlots dimension** | v1 A, v2 A | **Chosen** | Fewest mods; ids identical to survival so GlobalPos, lodestones, portals stay valid; swap is a plain stop/rename/start; sync can never touch the plot namespace folder |
| Mirror as a world-manager dimension (`/worlds create mirror <seed>`), swapped while unloaded | v1 B, v2 B | Fallback only | Lets the creative overworld be a hub. No lock API: a player teleporting in mid-swap races the copy, so a stop is needed anyway, removing the benefit. Dimension type, noise settings and seed must match by hand or seams appear. Copied villagers/lodestones reference `minecraft:overworld`, not the mirror id. Extra young dependency |
| Datapack noise dimension + Panda Per-World-Seed, datapack flat dimension | v2 C | Works, not recommended | No plot grid; hand-maintained, version-specific 26.x datapack |
| Sync the whole `world/` folder | v1 C | Rejected | Overwrites `world_gen_settings.dat` (plot dimension disappears) and creative's player data, scoreboard, game rules, mod data |
| Push from survival | v1 D, v2 F-11 | Rejected | A write-capable key for creative would sit on survival, the more exposed public server |
| `save-off` and rsync straight from the live world over the WAN | v1 E | Rejected | Saving stays off for as long as the transfer lasts; a dropped link risks leaving it off |
| Local snapshot on survival, pull from the snapshot | v1 F, v2 | **Chosen** | save-off window bounded to a local delta copy |
| Separate creative instance with same seed, **no copy** (M1) | Multiworld | Valid minimal variant | No contact with survival data at all, but survival builds never appear; "identical" only for ungenerated terrain (section 5.4) |
| One-shot world copy (M2) | Multiworld | Subsumed | The nightly sync is a repeated, scoped M2 |
| Live mirror (M4) | Multiworld | Impossible | No tool exists |

## 8. Findings and risks (merged, ranked)

Severity is for this deployment. "Answer" is how the canonical v2 design handles it; "v1" notes whether the superseded design had the same answer.

### High

**F-01 Region files cannot be replaced under a running dimension.** The server caches loaded chunks, keeps region files open and writes chunks back on save/unload; new `.mca` files underneath give a mix of old and new data, or new data overwritten by stale cached chunks. No 26.3 manager offers reload-from-disk (I; consistent with RegionCast copying only in `SERVER_STOPPED`). Multiverse's `clone` can hang the server (V). Syncing only some regions into a running mirror is unsafe for the same reason (I).
*Answer:* creative is stopped for the swap. New data is pre-staged next to the world (`mirror-sync/incoming/`, same filesystem) while creative still runs; the stopped phase is a few `rename(2)` calls. A journal (`SWAP_IN_PROGRESS`) plus `ExecStopPost=--recover` repairs a crash mid-swap. *v1:* stopped too, but copied with rsync while stopped (longer downtime, no journal, no rollback).

**F-02 `save-off` must always be undone, and must not be shared blindly.** Memory grows while saving is off (5.3). If the job dies with saving off, a later crash loses everything since. Subtler: this repo's backup also toggles `save-off`; an export sending `save-on` mid-backup would end the backup's window early and let it archive torn region files (I).
*Answer:* `.save-off-active` marker written before `save-off`; EXIT trap sends `save-on`; `ExecStopPost=--ensure-save-on` covers SIGKILL and timeouts; `timeout SAVE_OFF_MAX` caps the copy; the export takes `.backup.lock` and the instance operation lock (`SHARED_LOCKS`) so it never interleaves with backup, restore or rollback. `SOURCE_MODE=stage` removes the extra window entirely. *v1:* EXIT trap and timeouts only (no SIGKILL coverage, no backup lock), see section 9.

**F-03 rrsync restricted-directory escape, CVE-2026-53783.** Per the Debian security tracker (checked 2026-10-24): TOCTOU symlink race and options rrsync failed to block; fixed upstream in rsync 3.5.0 (2026-08-13); **bookworm 3.2.7-1+deb12u6 vulnerable**; trixie release pocket 3.4.1 vulnerable; fixed in trixie-security 3.5.0+ds1-0+deb13u1 (DSA-6527-1). Other 2026 rsync CVEs are also open on bookworm. V
*Answer:* (1) key in a dedicated shell-less `mcsync` account, so an escape cannot read `variables.txt`, RCON passwords or the live world; (2) `from=` pins the creative address; (3) `authorized_keys` root-owned; (4) export tree holds only regular files written by the export (no symlinks to race; `rsync -rt` without `-l` skips links); (5) trixie with trixie-security, or SSH reachable only over WireGuard on bookworm. **Re-check the tracker before deploying.** *v1:* key on the server user itself, so an escape exposes everything that user can read.

**F-04 26.1 moved every dimension** (section 4). Scripts written for the pre-26.1 tree copy the wrong paths or nothing.
*Answer:* all template paths use the 26.x layout; export refuses a world without `dimensions/`; dimensions come from an allowlist; `level-name` is read and validated.

**F-05 Any copy into or out of the live survival save is the most serious data-loss class** (multiworld research ranking). Confusing source and destination, copying live without a confirmed flush, or adding worldgen/runtime-world content to the real survival world can corrupt or lose it.
*Answer:* survival is only ever **read**, and only during the save-off window (or never, in stage mode). The survival host has no credential that writes anywhere; creative's key is read-only and jailed to the export tree.

### Medium

**F-06 Copy scope: chunk folders only.** Copying `level.dat`, `data/` or `players/` would overwrite creative's own scoreboard, game rules, plot ownership data kept by mods and inventories. Side effects of not copying `data/`: maps in item frames or chests show blank or a different creative map (map ids are global); active raids and forceloaded chunks do not carry over; world border, spawn and game rules set on survival do not propagate (set them once on creative). V/I
*Answer:* four isolation layers (10.4). Map blanking is accepted.

**F-07 Version parity.** 26.3 chunks (DataVersion 5023) cannot be loaded by an older server; a newer one upgrades them one way. V
*Answer:* manifest records `mc_version` from the survival log; pull refuses a mismatch (`REQUIRE_SAME_VERSION=1`). Upgrade both servers in the same maintenance window, **survival last**. *v1:* no check. Note the suite's `"latest"` version setting can resolve differently on two instances at different times (multiworld research), so pin explicit versions.

**F-08 Seed must match, and the seed moved.** See 5.4. *Answer:* set `level-seed` before the creative world is first created; record the seed in the manifest; check the mirror edge after the first sync; Panda Per-World-Seed as fallback. Even with a matching seed, expect local differences from MC-55596 and from any C2ME/mod difference.

**F-09 Worldgen content and mod parity.** Worldgen datapacks or mods (Terralith etc.) on only one side break equality for new chunks; mods that place blocks on survival must exist on creative or the blocks become air. C2ME build drift (5.5). I/R
*Answer:* keep worldgen-relevant mods, datapacks and the game version identical; pin jar versions. Not enforced by the scripts (C: a manifest field for the mod list would be needed).

**F-10 `save-all flush` freezes survival briefly**, scaled by dirty chunks. V/I
*Answer:* export at 04:40, off-peak and after the hourly backup at hh:20 (fewer dirty chunks); the window length is logged; stage mode reuses the backup's flush.

**F-11 Ecosystem maturity.** FabricPlots 1.0.x, one maintainer, stale description, fixed geometry; mc-worlds young with few users; RegionCast 83 downloads. V
*Answer:* depend only on FabricPlots and vanilla; pin versions; test upgrades on a copy; keep the plot dimension in creative backups.

**F-12 Two hosts on different networks.** Exposing survival SSH to the internet for one key, or creative's game port publicly, widens the attack surface. I
*Answer:* WireGuard between hosts (or between mc-router and both backends); `from=` uses the tunnel address; backends accept 25565 only from mc-router.

**F-13 Pull vs push trade-off.** Pull keeps survival credential-free; its cost is that creative cannot trigger the flush.
*Answer:* coordination by schedule and manifest (stale or already-applied snapshots refused). *v1:* creative triggered the snapshot remotely through a forced-command wrapper (`ping`/`snapshot`/rsync), which gives the creative key the power to cause `save-off` cycles on survival (C).

**F-14 Disk space.** Creative needs about 3x the mirrored dimension (cache + live + rollback; peak also 3x because the old rollback is dropped before pre-staging). Survival needs one full snapshot the first time, then only changed files per night (`--link-dest`). I
*Answer:* both scripts check `df` against an estimate plus margin and exit 73 without changing anything. Reflink filesystems (btrfs, XFS) make pre-staging nearly free.

**F-15 No shrink guard in v2 (C).** v2 verifies that the pulled cache matches the manifest's file count and byte total, which proves the **transfer** is complete, but nothing checks that the **snapshot itself** is plausible. If survival's `level-name` pointed at a freshly generated world, or the world was wiped, v2 would faithfully apply a tiny mirror. v1 had a guard: abort if any pulled dimension has no `.mca` file, or if the overworld region count falls below `MIN_REGION_RATIO_PCT` (50) of the current one.
*Answer:* none yet. Recommended: port v1's ratio check into v2's pull before `stop_server`, with `--force` to override. Also note mirror semantics: the sync uses delete, so griefing on survival appears on creative at the next refresh (v1 R10); creative is disposable and **never a backup or restore source** for survival (v1 R9).

**F-16 Survival rrsync options (T).** rrsync on the actual Debian version must accept the pull's options (`--delete-delay`, `--partial-dir`, `--timeout`, `--bwlimit`) and refuse `ssh ... id`, writes and paths outside the root. rrsync 3.5 forces `--no-D`. `rrsync` location: `/usr/bin/rrsync` from the rsync package on current Debian; older releases ship it as `/usr/share/doc/rsync/scripts/rrsync.gz` (`command -v rrsync`). V/T

### Low

**F-17 rsync flag pitfalls.** `-z` wastes CPU on already zlib/lz4 chunk payloads; `--checksum` reads every byte on both sides; `--inplace` leaves files inconsistent when interrupted and breaks `--link-dest` hard links; `-a` adds owner/group/device handling; `--contimeout` is daemon-mode only, so SSH needs `ConnectTimeout`/`ServerAliveInterval`. V
*Answer:* `-rt --partial-dir --delete-delay --timeout --bwlimit` plus ssh options. *v1:* used `-a`.

**F-18 `ionice` idle is not a dependable throttle.** It only works with schedulers that honour classes (BFQ); with `none`/`mq-deadline` it does nothing. During a save-off window, idle I/O can also starve behind the game server and **lengthen** the window. I
*Answer:* `--bwlimit` on the pull is the real cap; the export uses best-effort priority 7, not idle; `nice`/`ionice` on rrsync are best-effort extras. *v1:* used `ionice -c3` inside the save-off window and `IOSchedulingClass=idle` on the unit.

**F-19 Log-based completion detection.** Waiting for `Saved the game` must be anchored (`\]: Saved the game$`) so chat cannot fake it, must start after a recorded byte offset, and must follow `latest.log` rotation (inode change) at server start. This repo's existing pattern `\]: Saved the (game|world)` is anchored correctly. Combined with the 26.3 log-line removal note (5.3), the line itself is T.
*Answer:* `wait_log` with offset and inode tracking in both v2 templates; RCON reply check in RCON mode. *v1:* unanchored, no rotation handling.

**F-20 Players in the mirror.** Builds in the mirror vanish nightly; a player who logged out in the mirror may log in inside changed terrain. I
*Answer:* Dimensional Inventories pool and gamemode, MOTD or join message, optional Leukocyte read-only mode, 60-second in-game warning before each swap.

**F-21 Mirroring the End (C/I).** If `minecraft/the_end` is added to `MIRROR_DIMS`, v2 copies End terrain from survival but keeps creative's `ender_dragon_fight.dat` (dimension `data/` is never synced). The dragon-fight state (dragon killed, gateway positions, exit portal) can then disagree with the copied terrain. Overworld-only (the default) avoids this. T if the End is ever mirrored.

**F-22 `region-file-compression`.** Each chunk records its compression type, so mismatched settings should still read; keep both servers on the same value anyway. V (property exists since 1.20.5) / I (cross-reading)

**F-23 RCON is unencrypted.** If RCON replaces screen, bind it to localhost and keep the password in a root-owned config. V

### Informational

**F-24** Management protocol as a future replacement for screen/RCON confirmed saves (6.3). V
**F-25** itzg/mc-router v1.49.0 (2026-10-20): routes JSON with hot reload (`-routes-config-watch` or SIGHUP); refuses unmapped hostnames when no default is set; connection rate limit defaults to 1/s. V
**F-26** Resource cost of a second Fabric instance on a dedicated VM: one JVM (heap plus roughly 1.0 to 1.5 GB native headroom, Paper-specific source, R); `pause-when-empty-seconds=60` pauses an empty server. No measured figure exists (T).

## 9. v1 vs v2 design: what changed and what v1 still contributes

v1 is superseded; do not deploy its scripts. This table exists so nobody re-introduces a v1 behavior believing it is equivalent.

| Aspect | v1 (2026-10-23) | v2 (2026-10-24, canonical) | Note |
|---|---|---|---|
| Paths, users, units | `/srv/minecraft/...`, user `minecraft`, `minecraft-creative.service`, `/etc/mc-mirror/*.env` | Repo layout `/home/mc/minecraft-server/instances/<inst>`, user `mc`, `creative.service`, `/etc/mc-mirror/{export,pull}.conf` | Unit names are assumptions in both; adapt |
| Mirrored scope | 3 dimensions, whole folders | Overworld by default; `region/entities/poi` only | X6, X7, X8, F-21 |
| SSH account | Server user with forced-command wrapper `mc-mirror-export` (`ping`, `snapshot`, `rrsync -ro $STAGE`) | Dedicated `mcsync`, forced `rrsync -ro` only, root-owned `authorized_keys`, `/bin/sh` shell | F-03, F-13 |
| Who triggers the flush | Creative, remotely (`ssh ... snapshot`) | Survival's own timer; creative reads a manifest | Decoupled hosts |
| Survival snapshot | One mutable `mirror-stage/` dir, `.stamp` written after success, `rm -f .stamp` at start | Immutable `snapshots/<stamp>/` via `--link-dest`, atomic `LATEST`, keep >= 2 | v1's pull never checked `.stamp`, so a failed snapshot could not be distinguished from a good one by the puller (C) |
| save-off safety | EXIT trap, `FLUSH_TIMEOUT`, `COPY_TIMEOUT` | + `.save-off-active` marker, `ExecStopPost=--ensure-save-on`, shared backup/operation locks | v1's claim that a dropped session "can never leave survival with saving disabled" does not hold for SIGKILL/OOM (C) |
| Log wait | `grep -q "Saved the game"` from offset | Anchored regex, offset + inode | F-19 |
| Unreachable survival | `exit 0` with a log line (silent to alerting) | Retries on rc 10/12/30/35/255, then rc 69 + webhook | |
| Validation before swap | `.mca` present per dim; overworld count >= 50 % of current | Manifest id/age/dims/applied/version; file count and bytes match manifest | **v1's shrink guard is missing in v2 (F-15)** |
| Swap | Stop, then `rsync -a --delete` into the live folders, start | Pre-stage copy while running, stop, rename swap, start, health check (`Done (`), rollback to `failed/<stamp>` | v1 kept no rollback by default (suggested `--backup-dir` or a Proxmox snapshot) |
| Creative already stopped | Started anyway at the end | Swap applied, server left stopped | |
| Re-run with nothing new | Re-pulls and restarts creative | `APPLIED` matches: exit 0, no restart | |
| Disk check | Survival: 1.1x first run, else `MIN_FREE_KB`; creative: 1.2x current mirror + 1 GiB | Estimate from last manifest or `du` + margin; creative about 3x | |
| Throttling | `ionice -c3 nice -n19` in save-off; unit `IOSchedulingClass=idle` | best-effort 7 in export; `--bwlimit` on pull; `nice 19 ionice -c3` on rrsync | F-18 |
| Schedule | One timer, 04:30 +10 min random | Export 04:40, pull 05:15 +5 min random | |
| `ssh-keygen -a` | 64 | 100 | KDF rounds for the private key file |
| Stale-data monitor idea | `.stamp` older than 36 h should alert | `MAX_SNAPSHOT_AGE_H=30` refuses stale snapshots; doctor check proposed | |

## 10. Canonical design summary (v2)

Full detail and the scripts: [creative-mirror-sync-blueprint.md](creative-mirror-sync-blueprint.md).

```
 survival-server-vm (host A)                          creative-server-vm (host B)
 survival.service (screen + Fabric)                   creative.service (screen + Fabric)
  world/dimensions/minecraft/overworld                 world/dimensions/minecraft/overworld   <- swapped nightly
                                                       world/dimensions/fabricplots/plots     (never touched)
 04:40 mc-mirror-export.timer                         05:15 mc-mirror-pull.timer
  1. save-off + save-all flush (or reuse stage)        1. fetch LATEST manifest
  2. local copy -> snapshots/<stamp>    <-- rsync/ssh  2. delta-pull snapshot -> pull cache
  3. save-on                            read-only key  3. pre-stage copy next to the world
  4. publish LATEST manifest                           4. stop, rename swap, start
 ~mcsync: rrsync -ro on export root                    5. health check, rollback on failure
                  \______________ itzg/mc-router (edge) ______________/
                  survival.example.net                creative.example.net
```

### 10.1 Directory layout

Creative VM (`$HOME/<TARGET_DIR_NAME>/instances/<instance>` repo layout):

```
/home/mc/minecraft-server/
├── instances/creative/                      SERVER_DIR
│   ├── server.properties, mods/, config/fabricplots.properties, logs/latest.log
│   └── world/                               never synced as a whole
│       ├── level.dat                        NEVER synced
│       ├── data/minecraft/                  NEVER synced (scoreboard, maps, game_rules, world_gen_settings)
│       ├── players/{data,stats,advancements}/   NEVER synced
│       └── dimensions/
│           ├── minecraft/overworld/
│           │   ├── region/ entities/ poi/   replaced nightly
│           │   └── data/minecraft/          kept (raids, chunk_tickets, world_border)
│           ├── minecraft/the_nether/, the_end/   creative's own unless in MIRROR_DIMS
│           └── fabricplots/plots/           never touched (path inferred from id fabricplots:plots; verify after first boot)
└── mirror-sync/                             SYNC_ROOT: outside SERVER_DIR, same filesystem (script enforces both)
    ├── .pull.lock, LATEST.remote, APPLIED
    ├── cache/{MANIFEST,.INCOMPLETE,minecraft/overworld/...}   pull cache (delta target)
    ├── incoming/   rollback/   failed/<stamp>/ (kept 7 days)
    └── SWAP_IN_PROGRESS, STOPPED_BY_SYNC    exist only mid-swap / while stopped by the sync
```

`mirror-sync/` sits outside `SERVER_DIR` because the repo's backup archives the whole server directory (a cache inside would double every backup), and on the same filesystem so the swap is a `rename(2)`.

Survival VM:

```
/home/mc/minecraft-server/
├── instances/survival/world/dimensions/minecraft/overworld/{region,entities,poi}/   read only in the save-off window
├── backups/survival/{.backup.lock, .stage/mirror/..., .meta/last_backup.json}
└── mirror-export/                           EXPORT_ROOT, mode 2750, group mcsync
    ├── .export.lock, .save-off-active (only inside the window), LATEST (atomic)
    └── snapshots/<stamp>/{MANIFEST, minecraft/overworld/{region,entities,poi}/r.X.Z.mca}   immutable, keep >= 2
```

Manifest: plain `key=value`, parsed with `awk`, **never `source`d**: `format`, `snapshot`, `created_epoch`, `source_mode`, `mc_version`, `level_seed`, `dims`, `files`, `bytes`.

### 10.2 Export (survival, as the server user)

1. Locks: `.export.lock`, then every `SHARED_LOCKS` file (backup lock, instance operation lock), waiting up to `LOCK_WAIT`.
2. Preflight: `MIRROR_DIMS` allowlist (`minecraft/overworld|the_nether|the_end`), validated `level-name`, 26.x layout required, free space.
3. `live` mode with server running: marker, `save-off`, `save-all flush`, wait for anchored `]: Saved the game` (or RCON reply).
4. Local snapshot: per dimension and per `region entities poi`, `rsync -rt --link-dest=<previous> --include='r.*.*.mca' --exclude='*'` into `snapshots/.incoming.<stamp>/`, under `nice 10`/`ionice -c2 -n7` and `timeout SAVE_OFF_MAX`. rc 24 (vanished files) is a warning.
5. `save-on` immediately; EXIT trap and `ExecStopPost=--ensure-save-on` as backstops. `stage` mode skips 3 and 5: copies from `.stage/mirror` while holding the backup lock, refuses if `MIRROR_INCOMPLETE` exists or the stage is older than `STAGE_MAX_AGE_MIN`; **requires `BACKUP_STAGING_MODE=mirror`** (the `auto` default prefers reflink and keeps no persistent mirror).
6. Manifest, `mv -T` to `snapshots/<stamp>`, atomic replace of `LATEST`.
7. Prune to `KEEP_SNAPSHOTS` (>= 2, so a running pull never loses its files).

### 10.3 Transport

- SSH: ed25519, `BatchMode=yes`, `StrictHostKeyChecking=yes` against a pinned `known_hosts_mc_mirror`, `IdentitiesOnly=yes`, `ConnectTimeout=15`, `ServerAliveInterval=15`, `ServerAliveCountMax=4`.
- rsync: `-rt --delete-delay --partial-dir=.rsync-partial --timeout=600 --bwlimit`; root-anchored filters admit only `region/`, `entities/`, `poi/` and `r.*.*.mca` inside them.
- Retries only for rc 10, 12, 30, 35, 255; anything else fails fast. A failed pull leaves `.INCOMPLETE` and never touches creative; the next night resumes from the partial cache.

### 10.4 Path target isolation (four independent layers)

1. Export allowlist: only `minecraft/overworld|the_nether|the_end`.
2. Export content: only region files of `region/entities/poi`; never `level.dat`, `data/`, `players/`.
3. Pull filters: anchored includes accept nothing else, whatever the server sends.
4. Swap scope: renames exactly `world/dimensions/<dim>/{region,entities,poi}` per allowlisted dim. `fabricplots/plots`, `level.dat`, `data/`, `players/` and `dimensions/<dim>/data/` are never opened.

### 10.5 Service reload (creative)

1. Fetch `LATEST`; refuse if the id is malformed, older than `MAX_SNAPSHOT_AGE_H` (30), missing a configured dim, already `APPLIED` (exit 0, no restart unless `--force`), or a different MC version.
2. Drop the previous rollback, then space check.
3. Delta-pull into `cache/`; verify count and bytes against the manifest (`.rsync-partial` excluded from the count).
4. Only now take creative's `SHARED_LOCKS` (a long transfer never blocks local backups); copy `cache/` to `incoming/` with `cp -a --reflink=auto` while the server runs.
5. Warn (`say` at `WARN_SECONDS` and 10 s), write `STOPPED_BY_SYNC`, `sudo -n systemctl stop creative.service` (the repo unit runs `graceful_stop.sh`, which saves), wait until unit and screen are gone (`STOP_TIMEOUT`).
6. Swap with journal.
7. Start, wait for `]: Done (Ns)!` in a fresh `latest.log` (`START_TIMEOUT`); write `APPLIED`.
8. Start failure: stop, rejected folders to `failed/<stamp>/`, rollback renamed back, start again, report. Killed mid-swap: `ExecStopPost=--recover` replays the journal and restarts.
9. Server already stopped: swap applied, server left stopped, not start-tested.

Exit codes (sysexits): 0 ok, 65 stale/invalid snapshot, 69 source unavailable, 73 no space, 75 lock busy, 78 config error, 1 operational failure.

## 11. Security and access setup (essentials)

- Survival accounts: `mc` runs server and export; `mcsync` is a separate system account that only serves `rrsync -ro`. `mc` must be in group `mcsync` or Linux silently drops the setgid bit when the export creates directories. `mcsync` needs only search (`x`) permission on the parent directories (`setfacl -m u:mcsync:x ...` or `chmod o+x`).
- Survival `authorized_keys` (root-owned, mode 644, `.ssh` dir root-owned 755):

  ```
  restrict,from="<creative or WireGuard IP>",command="nice -n 19 ionice -c3 /usr/bin/rrsync -ro /home/mc/minecraft-server/mirror-export" ssh-ed25519 AAAA... mc-mirror@creative
  ```

  `restrict` disables PTY, forwarding and `~/.ssh/rc`; `command=` ignores the client's request (and its `--rsync-path`, hence `nice`/`ionice` inside); `mcsync` gets `/bin/sh` (dash) because rrsync's man page warns bash may read rc files before the forced command. Optional `Match User mcsync` block: `AuthenticationMethods publickey`, `PasswordAuthentication no`, `AllowTcpForwarding no`, `X11Forwarding no`, `PermitTTY no`.
- Creative: `ssh-keygen -t ed25519 -a 100 -N ''`; pin the host key with `ssh-keyscan` into a dedicated `known_hosts_mc_mirror` and **compare the fingerprint out of band** with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run on survival. Test that a listing works and `ssh ... id` is refused. No passphrase (unattended timer); the `restrict,from=,command=` line is the limit. `systemd-creds` plus an agent is possible but adds moving parts for little gain.
- A changed host key fails the pull (rc 255); it is never auto-accepted.
- Creative sudo: `mc ALL=(root) NOPASSWD: /usr/bin/systemctl start creative.service, /usr/bin/systemctl stop creative.service` (the repo's `docs/sudoers-setup.md` already installs this rule).
- Configs are root-owned, mode 640, group `mc`. Webhook URLs travel on curl's stdin so they never appear in `ps`.

## 12. Configuration, scheduling and error handling

### 12.1 Creative configuration essentials

```properties
# server.properties, before the very first start
level-name=world
level-seed=<survival seed, from /seed on survival>
level-type=minecraft\:normal
gamemode=creative
force-gamemode=false          # true only without Dimensional Inventories (X9)
region-file-compression=deflate
enable-rcon=false
# white-list defaults to true on 26.3: add players or set it deliberately
```

```properties
# config/fabricplots.properties: Dimensional Inventories owns gamemode switching
manage-gamemode=false
```

```text
/diminv pool plots create
/diminv pool plots dimension fabricplots:plots assign
/diminv pool plots gamemode creative
/diminv pool mirror create
/diminv pool mirror dimension minecraft:overworld assign
/diminv pool mirror gamemode creative      # or adventure/spectator for a look-only mirror
```

Optional read-only mirror: Leukocyte `/protect add mirror with minecraft:overworld`, deny `break`/`place`/`interact_blocks`. Players reach plots with `/plot world` or `/execute in fabricplots:plots run tp @s 0 65 0`. Every mod in the stack is server-side, so vanilla clients can join.

### 12.2 systemd

| Unit | Key settings |
|---|---|
| `mc-mirror-export.service` (survival) | `Type=oneshot`, `User=mc`, `ExecStopPost=... --ensure-save-on`, `TimeoutStartSec=1h`, `Nice=10`, `IOSchedulingClass=best-effort`, priority 7 (not idle, F-18), `PrivateTmp=true`, `ProtectSystem=full` |
| `mc-mirror-export.timer` | `OnCalendar=*-*-* 04:40:00`, `Persistent=true` |
| `mc-mirror-pull.service` (creative) | `Wants/After=network-online.target`, `After=creative.service`, `ExecStopPost=... --recover`, `TimeoutStartSec=3h`, `Nice=15`, best-effort 7, `PrivateTmp=true`, `ProtectSystem=full`; **no `NoNewPrivileges=`** (sudo needed) |
| `mc-mirror-pull.timer` | `OnCalendar=*-*-* 05:15:00`, `RandomizedDelaySec=5min`, `Persistent=true` |

Logs go to journald (`journalctl -t mc-mirror-export`, `-t mc-mirror-pull`); set `SystemMaxUse=` on small disks. Alerting: `WEBHOOK_URL` (Discord-style `{"content": ...}`) or `OnFailure=`. Re-apply the current snapshot: `mc-mirror-pull.sh --force`.

### 12.3 Error handling matrix

| Failure | Detected by | Effect | Recovery |
|---|---|---|---|
| Survival unreachable / ssh refused | rsync rc 255 | Retried `RETRIES` times; creative untouched | Next night; webhook |
| Transfer interrupted / stalled | rc 30, 12, 10 | Retried; partials kept; `.INCOMPLETE` stays | Next run resumes the delta |
| Snapshot pruned during pull | rc 23/24 | Fails fast | Next night pulls the new snapshot |
| Host key changed | rc 255 | Fails; never auto-accepts | Verify out of band, update pinned file |
| Export did not run | manifest age | rc 65 | Fix survival timer |
| Version mismatch | `mc_version` | rc 65 | Upgrade both together |
| Disk full | `df` preflight | rc 73, nothing changed | Free space |
| save-all never confirmed | log/RCON wait timeout | Export aborts, save-on sent | Check survival log/disk |
| Export killed in save-off | `.save-off-active` | `ExecStopPost --ensure-save-on` | Automatic |
| Creative fails to start on new data | no `Done (` in `START_TIMEOUT` | Rolled back | Inspect `failed/<stamp>` |
| Pull killed mid-swap | `SWAP_IN_PROGRESS` | `--recover` restores and starts | Automatic |
| Overlapping runs | `flock` | Second exits 75 | None |
| Survival world implausibly small | **not detected in v2** | Tiny mirror applied | F-15 |

## 13. Routing with itzg/mc-router

```json
{
  "default-server": null,
  "mappings": {
    "survival.example.net": "10.8.0.11:25565",
    "creative.example.net": "10.8.0.12:25565"
  }
}
```

Run with `-routes-config /etc/mc-router/routes.json -routes-config-watch` (or `-mapping host=addr` flags). Without `default-server`, unmapped hostnames (scanners) are refused. Raise `-connection-rate-limit` (default 1/s) if many players reconnect after the creative restart. Route backend traffic over WireGuard and firewall backends to accept 25565 only from mc-router; creative also accepts 22 only from admin hosts. Real client IPs need `-use-proxy-protocol` in mc-router **and** FabricProxy-Lite on both servers in the same change (one without the other breaks every connection), restricted with `-trusted-proxies`. During the swap, new connections to creative simply fail for the restart window; no router change is needed.

## 14. Fit with this repository

| ID | Finding | Implication |
|---|---|---|
| R-01 | No SSH, cross-host, sync or mc-router code exists; `docs/reverse-proxy.md` covers only the API wrapper on port 3030 | New feature area |
| R-02 | Backup staging mirror `$BACKUPS_PATH/.stage/mirror` is a flushed full copy refreshed hourly, but persists only with `BACKUP_STAGING_MODE=mirror`. `bk_private_dir` keeps `.stage` at mode 700, strips ACLs and requires single-owner files, so another account cannot read it. Refresh uses temp-plus-rename (no `--inplace`), so hard links into it would be content-safe, but permissions rule them out | `SOURCE_MODE=stage` copies (with `--link-dest` between snapshots), never hard-links the stage |
| R-03 | The repo schedules with **cron** (`create_backup_job.sh`, `create_restart_job.sh`, `cron_lib.sh`); no systemd timers exist. The brief asks for timers | **Open decision** (section 16) |
| R-04 | Backups take `$BACKUPS_PATH/.backup.lock` (`flock -n`, fd 9) and `scripts/<inst>/.locks/operation_<inst>.lock`; restore, rollback, restart and scheduled restart take the operation lock and exit 75 when held. `graceful_stop.sh` and `start.sh` take no lock | Listing both in `SHARED_LOCKS` serializes mirror jobs with all of them. A colliding backup is **skipped** (exit 75), not blocked; `BACKUP_SKIP_ALERT_AFTER` (3) alerts only on repeated skips. The templates do not write the repo's `.kind` helper file, so the "held by" message shows a stale kind |
| R-05 | `tests/js/webhookEvents.test.cjs` fails if a script emits an event missing from `KNOWN_WEBHOOK_EVENTS` (`src/setup/common/loadVariables.js`) | Add `mirror_export_failed`, `mirror_sync_complete`, `mirror_sync_failed` there and in the README; use `notify` from `webhook.sh` |
| R-06 | Config flows `variables.json` to `set_common_variables.js` to `variables.txt`; optional keys must be listed and validated in `loadVariables.js` and `bk_load_config` | A `MIRROR` block in `variables.example.json` plus those touch points |
| R-07 | Creative backups archive the whole server directory | Exclude the mirrored chunk folders with `BACKUP_EXTRA_EXCLUDES` (anchored, e.g. `/world/dimensions/minecraft/overworld/region`); keep the plot dimension in backups; keep `mirror-sync/` outside `SERVER_DIR`. After restoring such a backup, run the pull with `--force` (`APPLIED` still names the old snapshot) |
| R-08 | `world.js` (`discoverDimensions`) understands both layouts and datapack dimensions | Pruning chunks on survival (`prune-chunks.js`) shrinks every transfer; pruning the mirror is pointless |
| R-09 | Shell tests use shims (`tests/shell/shims/`) without an `ssh` shim; backup suites hang under Git Bash on Windows | Tests need an `ssh` shim modelled on the `rsync` one and must run on Linux CI |
| R-10 | Instance units use `PrivateTmp=true`, `ProtectSystem=full`, no `NoNewPrivileges` (screen and sudo) | Mirror units copy that; the export unit could be hardened further, but `ProtectSystem=full` was kept to avoid breaking screen's socket access |
| R-11 | Setup writes `max-players`, `motd`, `level-seed`, `white-list`, `difficulty`, `pvp`, `allow-flight`, `online-mode` and RCON keys; it does **not** write `server-port`, `gamemode`, `force-gamemode`, `level-name`, `level-type`, `generator-settings`, `accepts-transfers`. RCON uses one `RCON_PORT` for every instance. `pvp` is a stale key on 26.x (moved to a game rule) | A wizard route for a creative mirror must write gamemode settings; ports matter only if two instances share a host (not the brief's case) |
| R-12 | `JAVA.SERVER.VANILLA.VERSION="latest"` and the alpha fallback for mods (C2ME) can resolve differently on two instances set up at different times | Pin exact Minecraft, Fabric and mod versions on both VMs (F-07, F-09) |
| R-13 | Reusable pieces: `server_control.sh` (`save_and_wait`, `disable_auto_save`, `enable_auto_save`), `utils.sh` (`acquire_operation_lock`), `webhook.sh`, `doctor`, `--check` preflight, `manage.sh` instance discovery, API wrapper | See roadmap (section 17) |

## 15. Verification checklist before production

Run on staging copies of both servers (for example throwaway VM snapshots). Merged from v1 section 9, v2 audit section 6, and the mirror-relevant open questions of the multiworld research.

**Save and survival safety**
1. `save-all flush` during `save-off` writes region files (check `.mca` mtimes) and logs exactly `]: Saved the game` on Fabric 26.3; the RCON reply contains the same text (26.3 removed some log lines, 5.3).
2. Memory during a worst-case save-off window (busy evening world) stays within the heap; note the logged window length.
3. `systemctl kill -s KILL mc-mirror-export.service` during the window leads to `save-on` via `ExecStopPost`; the survival log shows `Automatic saving is now enabled`.
4. A backup and a restore started during export or pull are skipped with exit 75, not run concurrently.
5. If C2ME stays installed: `save-all flush` also flushes its async serializer (write blocks, flush, save-off, copy while chunks load, start a server on the copy, look for missing/corrupt chunks).

**World correctness**
6. `/seed` on both servers returns the same value.
7. FabricPlots creates `fabricplots:plots`; `find world/dimensions -maxdepth 2` confirms the folder is `dimensions/fabricplots/plots` (inferred so far). Plots survive several swaps unchanged (checksum `dimensions/fabricplots/plots/region` before and after; place a block in a plot, sync, confirm).
8. Creative loads mirrored chunks without "Failed to read chunk" or datafixer errors. Fly to a survival base: terrain and structures match.
9. The edge of the mirrored area shows no seam. Expect possible small feature differences (MC-55596); large terrain, biomes and structures must line up. Compare with and without C2ME if it is installed on either side.
10. FabricPlots starts on 26.3 without a separate sgui jar, or the missing-dependency message names sgui (X2).

**Transport and security**
11. rrsync on the actual Debian release accepts `--delete-delay`, `--partial-dir`, `--timeout`, `--bwlimit` (dry run) and refuses `ssh ... id`, writes and paths outside the root.
12. `apt-cache policy rsync` shows a version fixed for CVE-2026-53783 (trixie-security 3.5.x), or SSH is reachable only through WireGuard.
13. Block survival mid-transfer (`iptables -I OUTPUT -d <survival> -j DROP`): retries happen, the next run resumes from `.rsync-partial`, and creative was never stopped.

**Swap and recovery**
14. Run the pull twice: the second exits 0 with "already applied" and no restart.
15. `kill -9` the pull between the two `mv` calls: `--recover` repairs it and the server restarts.
16. Shrink free space below the estimate: both scripts exit 73 without changing anything.
17. Swap downtime (stop warning to `Done`) is acceptable; mc-router reconnects players.

**Not yet covered by any test or script**
18. Shrink guard behavior once ported (F-15): point survival at a fresh world and confirm the pull refuses it.

## 16. Open decisions for the maintainer

1. **Scheduler:** systemd timers (as the brief asks; gives `Persistent=`, `ExecStopPost=` recovery, journald) versus cron for consistency with the rest of the suite (R-03).
2. **Port v1's shrink guard into v2** (F-15) and pick the threshold.
3. **`SOURCE_MODE`:** `live` (own save-off window) or `stage` (no extra window, but requires `BACKUP_STAGING_MODE=mirror` and an hourly backup).
4. **Mirrored dimensions:** overworld only (default) or also nether/end (F-21 for the End).
5. **C2ME:** pin the same build on both VMs, or remove it from both (5.5).
6. **Mirror policy for players:** writable creative mirror (builds vanish nightly) or read-only via Leukocyte.

## 17. Integration roadmap (if this moves into the suite)

| Item | Value | Effort | Notes |
|---|---|---|---|
| Ship both scripts under `src/scripts/mirror/`, sourcing `server_control.sh`, `utils.sh` and `webhook.sh` instead of local copies | High | M | Reuses tested confirmed-save logic and lock semantics |
| `MIRROR` config block, validation, `KNOWN_WEBHOOK_EVENTS` entries | High | S | R-05, R-06 |
| Shell tests with an `ssh` shim; real-tool Linux CI job | High | M | R-09 |
| Shrink guard in the pull | High | S | F-15 |
| `manage.sh mirror export|pull|status` and a `doctor.sh` check (age of `APPLIED`/`LATEST`, `.save-off-active` leftovers, cache `.INCOMPLETE`) | Medium | S | |
| Scheduler decision | Medium | S | R-03 |
| Wizard route for "creative mirror" (mod stack, `level-seed`, gamemode keys, key setup instructions) | Medium | L | R-11 |
| Management protocol client for confirmed saves | Low | M | F-24 |

## 18. Not verified (summary)

- Every script: v2 is lint-clean but unexecuted; v1 is unlinted and superseded.
- FabricPlots' plot folder path, its sgui need on 26.3, and its long-term tracking of Minecraft releases.
- The 26.3 `Saved the game` log line and RCON replies after 26.3's log-line removals.
- rrsync option acceptance on the target Debian release.
- MC-55596 on 26.x; C2ME generation parity and flush behavior.
- Dedicated-server gamemode handling on 26.2+; datapack dimension folder path, removal and re-add; `level-type=minecraft:flat_all_dimensions`.
- Removal behavior of every world/plot/inventory mod.
- `ionice`, `--bwlimit`, timing and resource numbers: no benchmark was run. Tune `BWLIMIT`, `SAVE_OFF_MAX`, `RSYNC_TIMEOUT` after the first full pull.
- FabricProxy-Lite with mc-router PROXY protocol on 26.3; `/transfer` UX; Velocity on 26.3.
- RegionCast's 26.x path handling; Mirage Sync for 26.x; CurseForge-only projects (never searched).

## 19. Sources

Platform and versions:
- https://piston-meta.mojang.com/mc/game/version_manifest_v2.json
- https://meta.fabricmc.net/v2/versions/game, https://meta.fabricmc.net/v2/versions/loader, https://fabricmc.net/2026/03/14/261.html
- https://api.modrinth.com/v2/project/fabric-api/version, https://modrinth.com/mod/fabric-api/version/0.165.0+26.3
- https://minecraft.wiki/w/Java_Edition_26.1, .../Java_Edition_26.2, .../Java_Edition_26.3, .../Java_Edition_26.1_Snapshot_6, .../Data_version
- https://raw.githubusercontent.com/misode/mcmeta/26.3-summary/version.json

World format, commands, behavior:
- https://minecraft.wiki/w/Java_Edition_level_format, .../Region_file_format, .../Chunk_format, .../Dimension_definition, .../Server.properties, .../World_seed, .../Commands/save, .../RCON, .../Minecraft_Server_Management_Protocol (plus Game rule, Game mode, /transfer, Spawn protection, World preset, Superflat, Permission level, Player.dat format; several read through a summarizing fetcher, R)
- https://raw.githubusercontent.com/misode/mcmeta/26.3-data/data/minecraft/worldgen/world_preset/flat.json
- https://raw.githubusercontent.com/InventivetalentDev/minecraft-assets/26.1/assets/minecraft/lang/en_us.json
- https://github.com/PaperMC/Paper/issues/10657, SPIGOT-6383; Mojira MC-55596, MC-215960, MC-207625, MC-196653 (search summaries, R)
- https://github.com/itzg/docker-mc-backup

Mods and libraries:
- https://modrinth.com/mod/fabricplots, https://github.com/beachfury/fabricplots; sgui: https://maven.nucleoid.xyz/eu/pb4/sgui/
- https://modrinth.com/mod/mc-worlds (https://modrinth.com/project/rDdf0tz6), https://github.com/Wroud/mc-worlds
- https://modrinth.com/mod/melius-worldmanager, https://github.com/DrexHD/WorldManager
- https://modrinth.com/mod/multiworld (https://modrinth.com/project/fgvoNDL1), https://github.com/IsaiahMC/multiworld
- https://modrinth.com/mod/multiverse-dimensions, https://github.com/senseiwells/Multiverse
- https://github.com/NucleoidMC/fantasy
- https://modrinth.com/mod/dimensional-inventories, https://github.com/Thomilist/dimensional-inventories
- https://modrinth.com/mod/leukocyte, https://modrinth.com/mod/luckperms, https://modrinth.com/mod/pandaperworldseed
- https://modrinth.com/mod/regioncast, https://github.com/CodeW4VE/RegionCast; https://github.com/MRNOBODY-ZST/Mirage (Mirage Sync)
- Claims: https://github.com/thexaero/open-parties-and-claims, https://github.com/Flemmli97/Flan, https://github.com/Patbox/get-off-my-lawn-reserved
- C2ME: Modrinth `c2me-fabric`, https://github.com/RelativityMC/C2ME-fabric (branch `dev/26.3.0`)
- Ledger (QuiltServerTools/Ledger), Terralith and William Wythers' Overhauled Overworld (Modrinth)

Transport, security, scheduling, routing:
- https://download.samba.org/pub/rsync/rsync.1, https://download.samba.org/pub/rsync/rrsync.1, https://raw.githubusercontent.com/RsyncProject/rsync/master/NEWS.md
- https://security-tracker.debian.org/tracker/CVE-2026-53783
- https://packages.debian.org/bookworm/amd64/rsync/filelist, https://packages.debian.org/trixie/amd64/rsync/filelist, https://sources.debian.org/api/src/rsync/, https://sources.debian.org/api/src/systemd/
- https://man.openbsd.org/sshd.8, https://man.openbsd.org/ssh_config.5
- https://www.freedesktop.org/software/systemd/man/latest/ (systemd.timer, systemd.service, systemd.exec, systemd.resource-control)
- https://github.com/itzg/mc-router, https://api.github.com/repos/itzg/mc-router/releases
- https://modrinth.com/mod/fabricproxy-lite, https://github.com/OKTW-Network/FabricProxy-Lite
- https://docs.papermc.io/velocity/, https://docs.papermc.io/paper/aikars-flags/ (RAM headroom only), https://github.com/minekube/gate

Repository files consulted by the sources: `main.sh`, `src/common/setup.sh`, `src/setup/variables/set_server_properties.js`, `src/setup/common/loadVariables.js`, `src/setup/management/{create_service,create_backup_job,cron_lib}.sh`, `src/scripts/manage.sh`, `src/scripts/common/{server_control,utils,webhook,graceful_stop}.sh`, `src/scripts/backup/{backup,restore}.sh`, `src/scripts/backup/lib/{bk_common,bk_stage,bk_state}.sh`, `src/scripts/backup/automation/scheduled_restart.sh`, `src/scripts/{restart,smart_restart,rollback}.sh`, `src/scripts/world/lib/world.js`, `src/vanilla/download/*.txt`, `tests/js/webhookEvents.test.cjs`, `docs/backup-restore.md`, `docs/reverse-proxy.md`, `docs/sudoers-setup.md`, `docs/GLOSSARY.md`, `.shellcheckrc`.
