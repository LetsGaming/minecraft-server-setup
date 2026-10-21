# Research: mirror servers and multi-world support on Fabric/vanilla

Research date: 2026-10-20. Research only: no plan, no roadmap, nothing installed, downloaded, started or modified. Minecraft version yardstick: **26.3** (current stable, released 2026-09-15; 26.2 on 2026-06-16; 26.1.2 on 2026-04-09; 26.1 on 2026-03-24; 26.4 exists as snapshots only). Fabric API 0.164.0+26.3 and Fabric Loader 0.19.5 (stable) per Fabric meta and Modrinth. Java 25 is required since 26.1.

Labels: **V** = verified in a primary source (Mojang version manifest, Fabric meta, Modrinth API, mod repositories/READMEs read directly, vendor docs, man pages, and minecraft.wiki as the community mirror of Mojang changelogs). **I** = inferred by the researcher. **R** = reported (secondary, README promise, forum, or wiki text read through a summarizing fetcher). A README promise about mod behavior is **never** V for behavior; it is R. Where a statement names no version it applies to 26.3.

---

## 1. Executive Summary

**Mirror servers**
- **Same seed, creative, as a second instance: realistic and vanilla-capable (no mod), but "identical terrain" is only approximate.** A second server with the same exact Minecraft patch version, the same seed, the same world preset and the same worldgen-affecting content generates the same large-scale terrain (biomes, caves, structure positions) for chunks that have not been generated yet (I, from V facts in section 3). **Vanilla generation is itself not fully deterministic:** Mojira MC-55596 (unresolved, reported on versions 1.7.9 through 1.20.1; R, via search summary; not confirmed for 26.x) says some chunk features vary depending on chunk generation order, so two servers with the same seed can differ in details such as vegetation layout (see section 3.3 and Appendix A). `gamemode=creative` plus `force-gamemode=true` is vanilla (V). The match ends where players build in either world, and it ends for good if the two servers ever differ in Minecraft patch version or worldgen content.
- **Closer mirror by world copy:** vanilla-capable, works with `save-off` / `save-all flush` / copy / `save-on` (V). Safe only if the survival server is quiet or the copy is taken from an archive the suite already makes. The copy is **one-way and one-shot**; it diverges immediately.
- **Periodic sync:** no maintained tool exists for 26.x. The only one found (Mirage Sync) supports Minecraft 1.21.11 only, has 172 downloads, and was last released 2026-04-25 (V). Rolling your own with rsync over a live world is unsafe (I). A sync from a **stopped** server or from the suite's own backup archive is the only data-safe form.
- **Live or near-live mirroring: does not exist** for current versions. Queries and results are in section 6.

**Multiple worlds**
- **Several instances, one world each:** the vanilla-safe route, and the only one that needs no mod. It is what the suite's model already implies (one instance = directory + unit + `server.properties` + world), with real gaps in ports and config (section 2).
- **One server, several worlds:** there is no vanilla "worlds" concept in 26.1 to 26.3 (not found; absence is not proof). Vanilla gives **one save per process** with **many dimensions** inside it, and the world seed is shared by all of them. Datapack dimensions are vanilla-capable but cannot be created at runtime, cannot have their own seed, share gamemode/difficulty/game rules, and need a world reopen after changes (V/R).
- **Mods that add worlds:** four server-side Fabric mods are current on 26.3 (Worlds, World Manager, Multiverse by senseiwells, Multiworld). All are young or single-developer projects and none is a stable, established dependency (section 4.8).
- **Creative + survival on one server with separate inventories:** Dimensional Inventories is the only current server-side answer (it switches inventory and gamemode per dimension pool, V by README; R for behavior).
- **Plots:** one Fabric mod exists, FabricPlots, three months old, single developer, 3 stars. A PlotSquared equivalent with generic per-plot flags does not exist. A flat world is vanilla; claiming and protection are not.
- **Moving players between servers:** vanilla `/transfer` (since 1.20.5) works between two vanilla/Fabric servers with `accepts-transfers=true` on the target and needs permission level 3 to run, which command blocks do not have (V). Velocity is the established proxy and supports Fabric through FabricProxy-Lite (V), at the cost of a second JVM, a shared secret and a firewall rule.

**Difficulty (reasoning in section 5)**

| Capability | Minimum version | Fuller version |
|---|---|---|
| Mirror | Moderate (no mod, but the suite has real gaps; the hard part is guaranteeing "identical") | Hard (copy/sync safety, divergence handling, 26.1 layout; live mirror not realistically possible) |
| Multiple worlds | Moderate (separate instances, port and RAM handling) | Hard (mod stack with 1-developer dependencies, or datapack authoring); plots not realistically available beyond one young mod |

**Most serious risk:** any feature that copies, syncs or swaps world data **into or out of the survival server's live save** can corrupt or lose the real world. Specific hazards: copying without `save-off` + `save-all flush`; `save-off` does not freeze player, advancement and stat files (V); the 26.1 save layout moved player data, seed and game rules (V), so scripts written for the old layout can copy the wrong files; opening a copy with an older Minecraft version than the one that wrote it is unsupported and one-way (V/R); adding a world-generation mod such as Terralith to an existing world is documented as unsupported by its own README (V).

**Main limitations:** nothing was run, so no behavior in this report was observed. Several 26.x behaviors (dedicated-server gamemode handling, custom dimension folder path, `/transfer` UX, removal of runtime-world mods) are unverified and listed with their tests in section 7. Wiki pages were read through a summarizing fetcher (those items are R). The minecraft.net changelog could not be fetched. Subagents gathered the evidence; the report author did not re-fetch each source, except the project baseline, which was read directly.

---

## 2. Baseline: what the suite is today

Read read-only from `main.sh`, `src/common/setup.sh`, `src/setup/**`, `src/scripts/manage.sh`, `backup/backup.sh`, `world/lib/world.js`, `vanilla/download/*.txt`, `docs/GLOSSARY.md`.

**Instance model (V).** One `variables.json` holds one `INSTANCE_NAME` and one `TARGET_DIR_NAME`. Setup creates `$HOME/<TARGET_DIR_NAME>/instances/<name>/` (server), `scripts/<name>/` (runtime scripts), and `backups/<name>/`. The unit is `<name>.service` and runs `screen -DmS <name> bash start.sh`. `manage.sh` finds instances by scanning `scripts/*/common/variables.txt`. A second instance is a second setup run with a different `INSTANCE_NAME` (I from code; the README advertises "multi-instance management").

**What setup writes into `server.properties` (V, `set_server_properties.js`):** `max-players`, `motd`, `level-seed`, `white-list`, `difficulty`, `pvp`, `allow-flight`, `online-mode`, and when RCON is on, `enable-rcon`, `rcon.port`, `rcon.password`. **It does not write `server-port`, `gamemode`, `force-gamemode`, `level-name`, `level-type`, `generator-settings` or `accepts-transfers`.** Two instances on one host would both use 25565 unless the file is hand-edited; RCON uses the single configured `RCON_PORT` for any instance (V). Note that `pvp` and three other keys were removed from `server.properties` in 1.21.9 and became game rules (V, section 3), so `applyProperties` writing `pvp` is a stale key on 26.x (I; behavior of a removed key not tested).

**Versions and loader (V).** `JAVA.SERVER.VANILLA.VERSION` is `"latest"` or a version string; `USE_FABRIC` selects Fabric. Server jars are checked against Mojang's manifest SHA-1. Fabric mods come from `performance_mods.txt`, `utility_mods.txt`, `optional_mods.txt` (Modrinth slugs). The default lists include `lithium`, `c2me-fabric`, `krypton`, `chunky`, `essential-commands`, `anti-xray` among others. `c2me-fabric` rewrites chunk scheduling, I/O and generation (examined in Appendix A: all its builds are labelled alpha, the suite installs them because it falls back to an alpha when a mod has no release, and `PERFORMANCE_MODS` defaults to true in the example config). A `"latest"` version that resolves differently on the two instances at different times is the most direct way for a same-seed mirror to drift.

**Backups and locks (V).** `backup.sh` takes the operation lock, issues `save-off`, saves, `rsync`s into a temp tree (excluding logs, jars on request, `ledger.sqlite`), compresses with tar + zstd, and re-enables saving in an EXIT trap. A "confirmed save" depends on RCON reply or the "Saved the game" log line (glossary). `restore.sh` refuses while the server runs and swaps the world only after extraction succeeds. Operation lock per instance (`flock`, or `mkdir` fallback).

**Reusable pieces for a mirror or multi-world feature (V):** instance handling (`manage.sh`), backup/restore with confirmed-save logic and operation lock, `migrate.sh` and its plan/verify machinery, `doctor`, `--check` preflight (disk, tools, a `MemAvailable` warning in `loadVariables.js`), webhooks, the API wrapper (serves every instance on the machine), and `src/scripts/world/lib/world.js` (discovers dimensions; its comment documents both the pre-26 `DIM-1`/`DIM1` layout and the 26.x `dimensions/minecraft/<name>` layout; how it handles datapack dimensions was not read).

**What would need to be taught (V/I):** nothing in setup knows ports per instance, gamemode, seed discovery from an existing world, RAM budgeting across instances, or "this instance is a mirror of that one".

---

## 3. Ground Truth (worlds, dimensions, seeds, gamemodes)

Version-specific facts first, because 26.1 changed the world format.

### 3.1 Save layout in 26.1 through 26.3 (V, minecraft.wiki level format and 26.1 changelog)
26.1 restructured the whole save. The old layout (root `region/`, `DIM-1`, `DIM1`, `playerdata`, `stats`, `advancements`) does not apply from 26.1.

```
<level-name>/
  level.dat (+ _old, _new), session.lock
  players/{data,stats,advancements}/<uuid>.*
  data/minecraft/{game_rules,world_gen_settings,weather,world_clocks,scoreboard,...}.dat, maps/
  dimensions/minecraft/{overworld,the_nether,the_end}/{region,entities,poi,data/...}
  datapacks/, resourcepacks/, generated/
```

- **The seed is no longer in `level.dat`.** `WorldGenSettings` (seed, `generate_structures`, dimensions, bonus chest) moved to `data/minecraft/world_gen_settings.dat`. Game rules moved to `data/minecraft/game_rules.dat` (V). Any script that reads the seed from `level.dat` is wrong on 26.1 and later.
- `level.dat` still holds `GameType` (default gamemode int), `difficulty_settings` (difficulty is now a string), `DataPacks`, `spawn{dimension,pos,...}`, `DataVersion`, `version_history` (added in a 26.3 snapshot), `enabled_features`, `WasModded`, `ServerBrands` (V).
- Upgrade from 1.21.x to 26.1 is an automatic one-way conversion on first load. The Fabric 26.1 announcement tells players to back up because of "major changes to world storage" (V, fabricmc.net/2026/03/14/261.html). 26.3 reports "world upgrade" progress at startup through the management protocol (V).
- Custom (datapack) dimension folder path: the wiki lists only the three default dimensions. `dimensions/<namespace>/<path>/` is the expected form, and Multiverse's README states exactly that path for its dimensions (V for that mod). For vanilla datapack dimensions on 26.x it is I.
- `session.lock` holds one character and an OS lock; a second process on the same directory aborts (V). Exact message not captured.
- `ops.json`, `whitelist.json`, bans, `server.properties`, `usercache.json`, `eula.txt` live in the server working directory, not in the world (V/I). A world-folder copy does not carry them.

### 3.2 What one server process can and cannot do (V unless marked)
- One process = **one save** (`level-name`, which can be an absolute path or relative to `--universe`), one `server.properties`, one default gamemode, one difficulty, one hardcore flag, one set of game rules (global `game_rules.dat`), one set of player data, one seed. Many dimensions can live in the one save.
- No per-dimension game rules, gamemode, difficulty or seed in 26.1 to 26.3 were **found** (I read the wiki version pages; absence is not proof).
- 1.21.9 (25w35a) removed `pvp`, `spawn-monsters`, `allow-nether`, `enable-command-block` from `server.properties`; they became game rules. 26.1 turned all game rules into a registry with snake_case ids (V).
- 26.3 defaults (V, wiki default file): `white-list=true`, `pause-when-empty-seconds=60`, `accepts-transfers=false`, `server-port=25565`, `query.port=25565`, `rcon.port=25575`, `management-server-port=0`, `spawn-protection=16`, `gamemode=survival`, `force-gamemode=false`.
- `level-seed`, `level-type`, `generator-settings`, `generate-structures`, `hardcore`, `initial-*-packs` apply **at world creation** only; for an existing world the values come from the save (I for seed/type, V for hardcore/packs wording).
- `level-type` values: `minecraft:normal`, `flat`, `large_biomes`, `amplified`, `single_biome_surface` (V). `minecraft:flat_all_dimensions` preset added in 26.2 is hidden in the create screen; whether `level-type` accepts it is I (open question).

### 3.3 Seed determinism (what makes seeds equal or different)
- Same seed generates different new terrain when the generator changes between versions (V, wiki World seed). Recent 26.x generator changes: 26.2 added sulfur caves; 26.3 added the dappled forest biome, abandoned camps, fallen trees and a large worldgen datapack refactor (V). A 26.2 server and a 26.3 server with the same seed will differ in **chunks generated after the change** (I, very likely). Pinning the exact Minecraft **patch** version on both instances is therefore a precondition.
- Must also match (I from V facts): world preset (`level-type`, `generator-settings`), `generate-structures`, worldgen datapacks, `enabled_features`, and worldgen-changing mods. The seed applies to all dimensions; a datapack dimension cannot have its own seed ("the world seed is now always used for all dimensions", 22w11a, V).
- Fabric Loader + Fabric API alone should not change terrain; biome changes happen only when a mod calls the Biome API (R, 1.21.8 javadoc; the 26.x claim is I). Needs a test.
- Worldgen content packs break equality unless identical on both servers: Terralith 2.6.5+26.3 (server-side; README V: "You CANNOT remove Terralith from an existing world", not recommended to add to an existing world; requires Lithostitched), William Wythers' Overhauled Overworld 3.0.1 (V).
- Over time: chunks already generated stay as generated; chunks players modify diverge permanently. **Whether ungenerated chunks match exactly even with identical version and content is not guaranteed:** Mojira MC-55596 is a confirmed, unresolved bug ("chunks seem to have different variants between instances of worlds with the same seed", dependent on chunk generation order, seen in the Overworld and Nether, none known in the End, reported 1.7.9 through 1.20.1; R, read through a search summary because the Mojira page did not render). C2ME's README cites the same issue as the reason "worlds will vary significantly run-to-run even with the same seed" (V text, C2ME README and Modrinth page; the claim itself is R). Whether MC-55596 still reproduces in 26.x is untested. Consequence (I): exact block-for-block identity between two servers cannot be promised even without any mod; large-scale terrain, biomes and structure positions are far more stable than local features.

### 3.4 Gamemode mechanics
- `gamemode` = default for players without saved data; `force-gamemode=true` resets every player to the default on join (V, Server.properties). Per-player gamemode is stored in the player file (`playerGameType`, `previousPlayerGameType`) (R; file moved to `players/data/<uuid>.dat` in 26.1, V). A returning player in a copied world keeps the saved mode unless `force-gamemode=true` (I).
- 26.2: "As the host of a world, changing the game mode with F3+F4 or with commands now changes the default game mode of the world" (V text). Whether that applies to dedicated servers, and whether the dedicated server rewrites `level.dat` `GameType` from `server.properties` on start, is **not established**.
- Spawn protection: ops bypass it; automatically disabled when the server has no ops (V). The wiki says it only applies in the Overworld; that predates `spawn.dimension` in 26.x and is unverified for 26.x.
- Creative is a server-wide default in vanilla, not a per-world property.

### 3.5 World copy safety (V unless marked)
- `save-off` "disables the server writing to the level files (except player, advancement, stat files)"; changes queue in memory. `save-all flush` writes all players and chunks immediately and freezes the server briefly. `save-on` resumes (wiki /save-off, /save-all).
- Therefore a consistent online copy of the **world data** is `save-all flush`, `save-off`, copy, `save-on`; player, advancement and stat files can still change during the copy window (V), so a mirror should exclude `players/**` or copy them separately.
- 26.3 changelog: "Some log lines that server software might look out for have been removed. The Minecraft Server Management Protocol can be used instead" (V text; which lines is unknown). The suite's "confirmed save" in screen mode depends on a log line, so 26.3 behavior of that line needs a test (and the RCON reply path).
- Copy without `save-off`: torn region files and `entities/`/`poi/` out of sync with `region/` (I, standard).
- A world opened by an **older** server than the one that wrote it is unsupported; upgrades are one-way via DataFixerUpper (V for upgrade direction; dedicated-server refusal text is R). In 26.x the layout itself is migrated, so a 26.1+ world cannot be opened by 1.21.x at all (V).
- Different mod sets: on Fabric, removing a mod gives no warning; unknown blocks become air and unknown entities are dropped (R; no primary Fabric doc read). Adding mods to the creative copy is safe; removing content later loses it.
- What a creative counterpart needs (I from the V tree): `dimensions/**`, `data/minecraft/world_gen_settings.dat`, `level.dat`, `datapacks/` if worldgen-relevant. Probably exclude `players/**`, `session.lock`, `level.dat_old/_new`. Decide per file for `data/minecraft/*.dat` (game rules, weather, clocks, scoreboard, raids, border, tickets). Typical sizes: not measured (open question).

### 3.6 Datapack dimensions (vanilla-capable)
- Definition: `data/<ns>/dimension/<name>.json` with `type` and `generator` (`noise`, `flat`, `debug`); dimension types in `dimension_type/`. 26.1 added dimension type fields `default_clock` and `has_ender_dragon_fight` (V). `minecraft:void` as a generator is Bedrock-only; a Java void is a flat generator with air layers (V/I).
- Reach with `/execute in <ns>:<name> run tp @s ~ ~ ~`. Vanilla portals only go to the three vanilla dimensions (V/R).
- Added by opening the world with the datapack present; worldgen files are **not** applied by `/reload`; the client shows an experimental-settings warning (V/R); dedicated-server equivalent not established.
- Mojira reports (R, not readable): removing and re-adding a dimension loses registration data (MC-215960 and related).
- Datasets shared across dimensions: gamemode, difficulty, hardcore, player data, ops, datapack set, seed, game rules. World border data in 26.x is stored per dimension under `dimensions/.../data/minecraft/world_border.dat` (V tree); behavior for datapack dimensions is unknown.

### 3.7 Plot-style on vanilla
- Flat generator: `level-type=minecraft:flat` + `generator-settings` JSON (V). Void = flat with air layers (I).
- Vanilla protections: `spawn-protection`, adventure mode, world border, `can_place_on`/`can_break` item components (I), and command-block/function logic. **There is no vanilla claim system** (no page read describes one).

---

## 4. Approaches

Each entry: how it works, versions, vanilla vs mod, setup steps, operator maintenance, failure modes and data-loss risk, resource cost, fit with the constraints (Fabric target, terminal-only, no Docker, low bloat, setup complexity counts).

### 4.1 Mirror approaches

**M1. Separate instance, same seed, creative.** Vanilla-capable (V components, I composition).
- How: a second instance (new `INSTANCE_NAME`, distinct `server-port`, distinct `rcon.port` if RCON is on), same Minecraft patch version, same seed, same preset, same Fabric content that touches worldgen, `gamemode=creative`, `force-gamemode=true`. Creative operators can fly/build.
- Setup facts: if the survival world was created with an empty `SEED`, the seed lives in `world_gen_settings.dat` (26.1+) or is obtainable with the `/seed` command; a script must obtain it. Both instances must use the **same** Minecraft version: `"latest"` can resolve differently over time.
- Maintenance: version bumps must be coordinated; any worldgen mod/datapack change on one side only breaks equality for new chunks.
- Failure modes: terrain divergence after any version/content drift (silent); two servers fighting for port 25565; RAM overcommit; first start of the creative server writes `eula.txt` and a fresh `server.properties` with `white-list=true` on 26.3 (V default), so the creative instance rejects players until the whitelist is filled. No survival data is touched, so there is no data-loss risk to the real world.
- Resource cost: a second JVM (heap + off-heap; Aikar docs leave roughly 1.0 to 1.5 GB of host RAM beyond the heap, R as Paper-specific), a second world on disk that grows only where players explore, `pause-when-empty-seconds=60` pauses an empty server after a minute (V default). Measured idle cost: no primary figure exists (open question).
- Fit: best match to constraints. Cost for non-IT users: they must understand "same version, same seed" and ports; the suite does not write `server-port` or `gamemode` today (section 2).

**M2. World copy to a creative instance.** Vanilla-capable.
- How: `save-all flush`, `save-off`, copy world data, `save-on`; or copy from the suite's backup archive (which is already consistent); start the creative instance on the copy with `gamemode=creative`, `force-gamemode=true`.
- What to copy and exclude: section 3.5. `level.dat` carries spawn, time, weather, difficulty and datapack list; `data/minecraft/game_rules.dat` carries rules.
- Failure modes: torn files if `save-off`/flush is skipped or unconfirmed (log line removals in 26.3 are a risk); player files changing during the window (V); copied `session.lock` ignored but must not be copied into a running instance (I); running the creative copy on a **different Minecraft version** upgrades the copy one way (harmless to the survival world) but a **downgrade** is unsupported; mod set mismatches silently drop content (R). Writing into the creative copy while the survival copy's source is the live directory is a data-loss class risk only if the script's source and destination are confused; restore-style swap logic exists in the suite and is guarded (V).
- Size: whole world; sizes not measured.
- Fit: moderate. Reuses backup/restore machinery. The creative copy is a snapshot, and divergence starts at the first block placed.

**M3. Periodic or one-way sync.** Vanilla-capable at the file level; no maintained mod.
- Safe forms (I): (a) refresh the mirror from a **stopped** survival server; (b) refresh from the suite's most recent backup archive; (c) full replacement of the mirror's world directory while the mirror is stopped.
- Unsafe forms: `rsync --inplace` over a live world on either side; syncing only some regions into a running mirror (the mirror's loaded chunks overwrite on-disk files at save time; `entities/` and `poi/` can desync from `region/`) (I).
- Divergent builds in the mirror: any sync that overwrites replaces them; keeping them means selective region sync, which the mirror cannot do safely while loaded (I). A mod that does region pulling exists (Mirage Sync), see below.
- **Mirage Sync** (`mirage-sync`, MRNOBODY-ZST/Mirage, MIT, Fabric): MC **1.21.11 only**, latest 1.2.0 on 2026-04-25, 172 downloads, install path is build from source (R). README (R, not verified behavior): main server listens on a Netty port with a shared token; the mirror pulls changed `.mca` files by SHA-256, kicks players in the target dimension, force-saves, disables saving, unloads chunks, swaps files. Region files only; default auto-sync off. **Not usable on 26.x**, and three Minecraft releases behind.
- Cost to carry on suite machinery: backups and cron already exist; a cron job that restores the latest archive into the mirror directory while the mirror is stopped uses existing primitives (I). It must handle the 26.1 layout and exclude `players/**`.

**M4. Live or near-live mirroring.** Does not exist for 26.x (section 6). Mirage Sync is periodic, stale, and the only candidate. ChunkSync (1.21.11 only) syncs neighboring chunks inside one world, not across servers (R). Ledger (current on 26.3, 1.3.25) logs and rolls back block changes but nothing replays its records elsewhere (V/R).

### 4.2 Multi-world approaches

**W1. Multiple server instances, one world each.** Vanilla.
- How: one instance per world, each with its own `server-port`, `rcon.port` (and `query.port` if used), directory, unit and screen session (V per section 3.2). Players join each by `host:port`, by DNS name/SRV (R), via `/transfer`, or via a proxy.
- Resource cost: one JVM per world; per-process heap plus native overhead; shared disk. `management-server-port=0` self-avoids clashes (V); RCON and query ports do not.
- Failure modes: port collision; RAM overcommit (OOM kill under `MemoryMax`, V man page); ops/whitelist/bans are per instance with no official sharing (V); `session.lock` forbids two instances on one world directory (V).
- Fit: the lowest-risk route, and it matches the suite's existing instance model; the missing pieces are port assignment and RAM budgeting, plus any shared player lists.

**W2. Datapack-added dimensions.** Vanilla-capable (V/R, section 3.6).
- What a datapack can define: generator (flat/noise/debug), biome source, dimension type; not a seed (the world seed is used), not gamemode, not difficulty, not game rules.
- Reach: `/execute in ... run tp`; portals need datapack logic. Changes need a world reopen; removal behavior is uncertain (R: Mojira reports).
- Cost to the operator: hand-authored JSON; version-specific (datapack format 107.1 in 26.2, 121.0 in 26.3, V; a pack for 26.2 may not load on 26.3, I). Hand-editing JSON is the cost the suite's brief names for non-IT users.
- Data-loss risk: adding to or removing from the **real survival world** touches the registered dimension set; the removal case is unverified; backups first.
- Fit: vanilla, but poor non-IT fit and no per-world rules.

**W3. Fabric mods for multi-world / dimension management.** Mod-dependent. All four are server-side (R/V per Modrinth fields), all require Fabric API, and all depend on Minecraft-version-specific releases, so each mod is a dependency with a release-lag cost.

| Mod | State on 26.3 | Notes (behavior claims are R unless marked) |
|---|---|---|
| Fantasy (library, NucleoidMC/fantasy) | 0.8.4+26.3, 149 stars, pushed 2026-09-17 | Library, not an end-user mod: runtime persistent/temporary dimensions with per-level seed, difficulty, game rules (V, README); persistent dimensions must be reopened by the consuming mod after restart (V) |
| Worlds (`mc-worlds`, Wroud) | 1.10.0 for 26.3 (2026-10-07), MIT, 17.6k downloads, 1 star, one developer, about 40 releases in 13 months | Per-world game rules, time, weather, seed argument; auto-unload after one minute empty; README requires 26.3 / Java 25; fast churn |
| World Manager (`melius-worldmanager`, DrexHD) | 1.5.1+26.3 (2026-09-24), MIT, 15k downloads, 9 stars | create/delete/tp/import/export; GUI; no per-world rules listed |
| Multiverse (`multiverse-dimensions`, senseiwells) | 0.6.0+26.3 (2026-09-15), MIT, still 0.x, 6.8k downloads | create/delete/**clone** dimension, per-dimension game rules and tick rate, vanilla trio with portals; needs Fabric Language Kotlin; files in `world/dimensions/<ns>/<path>/` (V) |
| Multiworld (`multiworld`, IsaiahMC) | 1.14.2 for 26.2/26.3 (2026-10-09), LGPL, 84k downloads, **117 open issues**, README lists delete as both present and "coming soon" | per-world gamerule/difficulty (R); uses Fantasy |
| World Portal / Dimension Link (mahmudindev) | 26.3, ARR license | Redirect portals only; cannot create dimensions (V text) |

- **Not usable for 26.x (last built for 1.21.11 or earlier):** Multiworld Inventories, MultiWorld Positions, WorldEngine, Seeded Dimensions, Creativerse, PrivateCreative (V per Modrinth).
- Removal behavior of any runtime-world mod is **not established**. Only Multiverse documents where files live; Worlds' changelog shows it keeps stored generators it cannot decode (V text). Terralith-style "cannot be removed" warnings suggest caution for any content that registers dimensions or worldgen (I).
- Each mod's cost: Java 25 and Fabric API on every Minecraft bump; wait for the mod to release after each Minecraft release (lags observed: Multiworld about 6 weeks after 26.1, Multiverse about 2 months for 26.1.2); a failure to update strands the server on the old Minecraft version or forces removal.

**W4. Per-world gamemode and inventories on one server.** Mod-dependent.
- **Dimensional Inventories** (`dimensional-inventories`, Thomilist): 2.2.2+26.3 (2026-09-16), MIT, server-only, Fabric API only, 12.9k downloads, 5 stars, 12 open issues; 36 versions since 2023; releases 2 to 8 weeks after each Minecraft release (V per Modrinth). README (R): "dimension pools" share inventory, ender chest, XP, health and **gamemode**; leaving a pool saves and clears the inventory and loads the destination pool's; entities crossing pools are deleted; advancement and stats can be switched per pool. Built "to add a separate creative world to a survival server using a custom dimension datapack". Does not do difficulty or game rules.
- Removal: per-pool inventory files stay on disk; players keep what is loaded (I).
- The vanilla alternative, `force-gamemode` on a **separate instance**, achieves the same with no mod but with a second JVM.

**W5. Plot-style worlds without Bukkit plugins.**
- Honest state: a flat or void-like dimension is vanilla (section 3.7). Plot claiming, ownership, trust, merging and per-plot flags need a mod. **FabricPlots** (`fabricplots`, beachfury): 1.0.2 for 26.3 (2026-09-24), MIT, created 2026-06-27, 889 downloads, 3 stars, 5 open issues, one developer; README (R) lists a flat plot dimension with road grid, `/plot claim|auto|home|visit`, trust/deny, merging, per-player claim limits, a fixed set of toggles (PvP, biome, mob spawns), inactivity expiry, and a bundled mini-editor; "forces creative inside, survival outside". It does **not** isolate inventories itself; its README says to pair it with Dimensional Inventories and set `manage-gamemode=false`. Its README header is stale relative to the 26.3 file (R). No evidence about long-run tracking of Minecraft releases beyond 26.1.2 to 26.3.
- Chunk/anchor claim mods (Open Parties and Claims 0.33.0 labelled beta with 102 open issues and 23.9M downloads; Flan 1.12.8.b with an All Rights Reserved license; GOML-Reserved 1.22.0 tagged rc-1 for 26.3 and requiring Polymer) are **claims in a survival world, not a plot grid** (R/V per Modrinth). Newer claim mods (ClaimMod, TheLandClaim) are young, closed-source or not on 26.3.
- **Not available:** a PlotSquared equivalent with a generic flag system, plot-world import, and the long maintenance record that implies. Vanilla-only protection (adventure mode, spawn protection, command blocks) has no primary source read and no ownership primitive.

**W6. Moving players between servers.**

*Vanilla `/transfer` (Java 1.20.5+, V).*
- `/transfer <host> [port] [players]`, permission level 3, dedicated servers only. Target must have `accepts-transfers=true` (default false) and approves the transfer; the client reconnects with handshake intent 3 into the Login state; resource packs and cookies persist across a transfer (cookies up to 5 KiB, cleared on a real disconnect).
- Not established: whether the client shows a confirmation, the disconnect text on refusal, and re-authentication on the target (I: yes with `online-mode=true`, because it passes through Login). Player data does not move (I, near certain); there is no vanilla command to read or write cookies.
- Triggers: command blocks and functions run at level 2 by default (`function-permission-level=2`), so they cannot run it without raising that level or using a higher-privilege source; RCON/console can (I). Whether the 26.x permission changes alter this is untested.
- 26.4 snapshots (not released) add a `properties` map to the transfer and an `allowed-connection-ids` key (V, 26.4-snapshot wiki), the first vanilla metadata carrier for a transfer.
- Cost: no mod, no extra process; no shared inventory; each server must authenticate the player.

*Server Management Protocol (1.21.9+, 3.1.0 in 26.3, V).* JSON-RPC over WebSocket, disabled by default, 40-character secret, TLS default on, per instance. Covers allowlist, operators, bans, kick, game rules, settings, save, stop. It is a programmatic path to keep lists in sync across instances and a candidate replacement for log-line scraping; whether it can run `/transfer` is unknown.

*Velocity proxy* (not Bukkit-family; PaperMC/Velocity, GPLv3): 4.3.0 (2026-10-18), requires Java 25, docs state support for Minecraft 1.7.2 through 26.3 (V). Standalone Java process with `velocity.toml` (`[servers]`, `try`, `[forced-hosts]`, `player-info-forwarding-mode`, `forwarding.secret`). `/server` is permitted for everyone by default (V). Vanilla servers lack forwarding support (V docs), so Velocity is only meaningful for **Fabric** backends with **FabricProxy-Lite** 2.12.0 (2026-03-28, MIT, server-only, lists 26.1 to 26.3, V), configured with the same secret (`hackOnlineMode` defaults to true so the backend can keep `online-mode=true`). CrossStitch (the docs' optional companion) has not been updated since 2025-08 and does not list 26.x (V). Backends must be bound to `127.0.0.1` or firewalled: an `online-mode=false` backend reachable directly allows impersonation (V, docs). Cost: one more JVM and unit, a shared secret file, firewall/localhost binding, and two version couplings (Velocity and FabricProxy-Lite) on every Minecraft bump; chat-signing kicks are a documented failure mode (V docs; `hackMessageChain` is FabricProxy-Lite's fix, R). Other proxies: Gate (Go, Apache-2.0, very active; Fabric forwarding not checked), mc-router (Go, hostname routing, Docker-centric), Infrared (stale alpha). No Fabric-native proxy was found.

*Plain baseline:* two entries in the client's server list, `host:25565` and `host:25566`; SRV or hostnames are possible (R). No suite or mod needed.

### 4.3 Comparison table

| Approach | Vanilla or mod | Setup cost for non-IT | Data-loss risk to survival | Resource cost | Fit with constraints |
|---|---|---|---|---|---|
| M1 same seed, separate instance | Vanilla | Medium (version pin, seed, ports) | None (separate world) | +1 JVM, grows with exploration | Good |
| M2 world copy | Vanilla | Medium-high (flush, exclusions, layout) | Low if from an archive; high if live-copy or restore swaps are mishandled | +1 JVM, full-size world | Good, reuses backups |
| M3 periodic sync | Vanilla file ops; no maintained mod | High | Medium (live sync unsafe); low from stopped server/archive | +1 JVM, repeated copies | Workable only as "refresh from archive" |
| M4 live mirror | Does not exist | n/a | n/a | n/a | Not available |
| W1 multi-instance | Vanilla | Medium (ports, RAM) | None | +1 JVM per world | Best fit |
| W2 datapack dimensions | Vanilla | High (hand-authored JSON, version-specific) | Medium (modifies the real world's dimension set; removal unverified) | Same JVM | Weak for non-IT, no per-world rules |
| W3 world-management mod | Mod | Medium | Medium (mod removal unknown; real world modified) | Same JVM | Dependency with release lag |
| W4 Dimensional Inventories | Mod | Medium | Low-medium (inventory files) | Same JVM | One mod, solid record |
| W5 FabricPlots | Mod | Medium | Medium (plot dimension persists; young project) | Same JVM | High-risk dependency |
| W6a `/transfer` | Vanilla | Medium (accepts-transfers, op level) | None | none | Vanilla, minimal |
| W6b Velocity + FabricProxy-Lite | Separate process + mod | High | None to worlds; security if misconfigured | +1 JVM | Heavy for non-IT |

---

## 5. Feasibility Assessment

### 5.1 Mirror

**Minimum viable version (same seed, creative, separate instance).**
- Needs from the suite: ability to create a second instance from a template that inherits Minecraft patch version, loader and worldgen-relevant content from the first; `server-port` (and `rcon.port`) written per instance; `gamemode=creative` and `force-gamemode=true`; the seed obtained from the existing world (26.1+: `world_gen_settings.dat` or `/seed`) or provided by the user; first-start whitelist handling (26.3 defaults `white-list=true`).
- Must be asked: whether to mirror which instance (a choice a non-IT user can make by name), whether to keep versions pinned (explain "latest" drift), and creative gamemode. The seed and version are discoverable, not user questions.
- Must be detected or validated: both instances on the same exact Minecraft patch version; same Fabric content set for anything that affects worldgen (and the default mod lists include `c2me-fabric` and `lithium`, whose effect on generation was not examined); free ports; RAM for two heaps against `MemAvailable`; disk space.
- Interactions: backups (a second backup job for the mirror, or deliberately none); migration (`migrate.sh` and the plan/verify machinery assume one instance); `doctor` (needs per-instance checks, already per `INSTANCE_NAME`); API wrapper (already serves every instance); crash-loop limits (per unit).
- Risks: silent drift of terrain (not data loss); port collision; RAM overcommit. No contact with the survival world.
- **Difficulty: moderate.** No mod, no new process, but the suite today writes no per-instance port or gamemode, assumes one `variables.json` per setup run, and "identical" has to be guaranteed by version pinning that the suite does not currently offer for `"latest"`.

**Fuller version (copy or refresh).**
- Needs: a consistent world snapshot (the backup archive is the safest source); layout awareness for 26.1+; exclusion of `players/**`; a stop-before-replace rule on the mirror; a policy for divergent mirror builds (they are overwritten); version parity check before copying (copying a newer world into an older mirror is unsupported).
- Detected/validated: confirmed save (log line changes in 26.3), mirror stopped, same version, free disk (full world size), Fabric mod parity (unknown blocks become air).
- Risks: **corrupting or losing the real world** if the direction of copy is confused or if the survival side is copied live; wrong files copied under the 26.1 layout; version downgrade; overwriting builds the mirror's users made.
- **Difficulty: hard** for a safe, automated, repeatable refresh; **not realistically possible** for live mirroring (nothing exists).

**Dependency verdict.** The minimum version needs no mod and no extra process. A mod would only be justified for periodic region-level sync, and the only candidate is unmaintained for 26.x.

### 5.2 Multiple worlds

**Minimum viable version (several instances).**
- Needs: per-instance ports, RAM budget, naming, distinct systemd units and screen sessions (already per name); docs for players on joining by port or `/transfer`.
- Must be asked: how many worlds, names, and RAM for each; port numbers can be assigned automatically.
- Detected/validated: unique ports across instances (including RCON and query), summed heaps plus off-heap against RAM, disk, `session.lock` conflicts (distinct world directories).
- Interactions: backups per instance (existing), `manage.sh` multi-instance (existing), API wrapper (existing), shared whitelist/ops (none in vanilla; Management Protocol could sync, unverified for a script).
- **Difficulty: moderate.** No dependencies.

**Fuller version, one server, several worlds.**
- Datapack dimensions (vanilla): **hard** for non-IT (hand-authored JSON, version-specific formats, uncertain removal), and cannot give per-world gamemode, difficulty or seed.
- Mod stack (Worlds or Multiverse or World Manager, plus Dimensional Inventories, plus FabricPlots for plots): **hard**. Each adds a dependency on a project with one developer and a release lag; removal behavior is unverified; the survival world is modified by registering new dimensions; they require Java 25 and Fabric API at matching versions.
- Plot-style with generic per-plot flags: **not realistically possible** under the constraints beyond FabricPlots' fixed toggles.
- Seed-identical world plus plot world on one creative server: **hard**. A same-seed runtime world is a Fantasy-based mod feature (per-world seed argument, R) and the plot world is FabricPlots, with Dimensional Inventories if pools are wanted; or **moderate** if done as two instances joined by `/transfer` or by port.

**Moving players.** Manual port switching: trivial. `/transfer`: moderate (needs `accepts-transfers=true`, an op or RCON caller, and a manual trigger; no state transfer). Velocity + FabricProxy-Lite: hard for non-IT (separate process, secret, firewall).

**Failure and data-loss summary (ranked).**
1. Any copy/sync into or out of the live survival save (section 3.5).
2. Adding runtime-world or worldgen content to the **real** survival world (Terralith warning; removal unverified; datapack dimension removal reports).
3. Layout assumptions: scripts written for pre-26.1 trees copy the wrong paths.
4. Version drift: silent terrain divergence for mirrors; one-way upgrades.
5. Port/RAM collisions across instances; OOM kill under `MemoryMax`.
6. Proxy misconfiguration: impersonation on `online-mode=false` backends.

---

## 6. Excluded and Not Available

**Gaps relative to the Bukkit ecosystem (named as gaps, not recommendations; plugins are not adoptable).**
- Multiverse (Bukkit): many worlds with per-world gamemode, difficulty, portals, inventories. Fabric/vanilla: no vanilla concept; four young Fabric mods cover parts; per-world difficulty and gamemode are mostly missing.
- Multiverse-Inventories: per-world inventories. Fabric: Dimensional Inventories (pools).
- PlotSquared: plot grid with flags, rating, merging. Fabric: FabricPlots covers a subset; no generic flag system.
- WorldGuard: regions and flags. Fabric: claim mods (chunk/anchor claims), no flag registry equivalent.
- BungeeCord plugins for shared bans and data. Vanilla: none; Management Protocol per instance.
- Shared inventory across servers: no vanilla mechanism; the only Fabric tool found (Magnus) needs Redis + PostgreSQL and targets 1.21.10/1.21.11.

**Ruled out by the constraints.** Anything built on Paper/Spigot/Purpur/Folia; Cardboard (Bukkit-on-Fabric, Ledger declares it incompatible); Docker-first routers such as mc-router for the proxy role; web panels; mods with client-required installation for server-side features (excluded where a server-only alternative exists). Mixed-loader Modrinth listings (LuckPerms, WorldEdit, PlayerDataSync, Chronos Backups, PrivateCreative) must be checked per file for the Fabric build; PlayerDataSync is a multi-platform alpha with a Bukkit lineage and was not accepted as a Fabric answer.

**Does not exist for current versions (as searched).**
- Live or near-live block/chunk mirroring between servers. Queries tried include mirror world/server, world sync, replication, region file sync, cross-server sync; results: Mirage Sync (periodic, 1.21.11), ChunkSync (intra-world, 1.21.11), Creativerse (16x16x16 clone inside one world, 1.21.11), Ledger (logging only). CurseForge-only projects were not searchable.
- A PlotSquared-equivalent with generic flags.
- A per-dimension gamemode/difficulty mod beyond Dimensional Inventories (gamemode only).
- A current "fixed seed per dimension" mod (Seeded Dimensions stops at 1.21.11); per-world seeds exist only as arguments of the runtime-world mods.
- A tool replaying Ledger logs onto another server.
- Vanilla per-dimension game rules, gamemode or difficulty (not found in 26.1 to 26.3).

---

## 7. Open Questions

Each item names the test or source that would settle it.

1. **Same seed across patch versions, with Fabric API, and with the suite's default performance mods.** Compare chunk data (hash of region files plus a block-level diff of a sample area) for the same seed on 26.3 vs 26.2 vs 26.1.2, with and without Fabric API, with and without `c2me-fabric`, `lithium` and the other defaults, with C2ME's native-math and density-function-compiler options on and off, with different chunk-visiting orders, and two repeated runs of the same configuration (to measure the MC-55596 baseline). Test on throwaway instances.
2. **Dedicated-server gamemode handling.** Does `/gamemode` or startup overwrite `level.dat` `GameType`? Does `gamemode` in `server.properties` apply to an existing world's default? Test: change `gamemode`, restart, read `level.dat`; run `/gamemode`, re-read.
3. **Confirmed-save signal on 26.3.** Which log lines were removed; what RCON replies to `save-all flush`, `save-off`, `save-on`. Test: run each command through console and RCON and capture output; also read the Management Protocol's save method.
4. **Datapack dimension on a dedicated server.** Folder path; whether the experimental confirmation is needed; behavior when the datapack is removed; whether data survives re-adding. Test: add a flat test dimension, build, remove, restart, re-add.
5. **`level-type=minecraft:flat_all_dimensions`.** Accepted by `server.properties`? What it generates? Test on a throwaway server.
6. **Removal of Worlds, World Manager, Multiverse, Multiworld, Dimensional Inventories and FabricPlots.** What stays on disk and what happens to players inside. Test per mod with a throwaway world.
7. **`/multiverse clone` and seed.** Does the clone keep the original seed and does it work for a copy of the overworld? Read the source or test.
8. **`/transfer` behavior.** Client prompt, refusal text, re-authentication, caller permissions from RCON/function/command block under the 26.x permission model, and whether the Management Protocol can run it. Test with two instances.
9. **Velocity 4.3.0 with FabricProxy-Lite 2.12.0 on 26.3**, including chat-signature handling on `/server` switches; whether Velocity 3.x supports 26.x; Gate with Fabric forwarding.
10. **Measured resource costs.** Idle CPU and resident memory of a second Fabric 26.3 instance; JVM native overhead (`jcmd VM.native_memory`); world sizes. Test with two instances over ten minutes empty.
11. **Spawn protection and world border in 26.x** for datapack dimensions; whether protection follows `spawn.dimension`.
12. **26.1 migration of an existing suite-managed server.** Behavior of the suite's backup, restore, prune and `migrate.sh` against both layouts; how `world.js` handles datapack dimensions.
13. **Old camelCase game rule names on 26.x** (aliases?), relevant for any script issuing `gamerule`.
14. **Fabric registry sync / missing registry behavior** from primary Fabric docs (only R read).
15. **Mirage Sync's actual behavior and any 26.x port**; whether other CurseForge-only tools exist.
16. **`white-list=true` default on 26.3** and `pvp` handling: how the suite's `applyProperties` interacts with the removed key (not tested).

---

## 8. Sources

**Version and platform**
- Mojang version manifest: https://piston-meta.mojang.com/mc/game/version_manifest_v2.json (26.3 latest release, 2026-10-20)
- Fabric meta: https://meta.fabricmc.net/v2/versions/game and /v2/versions ; Fabric 26.1 announcement: https://fabricmc.net/2026/03/14/261.html
- Modrinth API (project/version endpoints) for Fabric API, all mods named below.

**Minecraft Wiki (read through a summarizing fetcher; treat exact wording as R)**
- Java Edition level format: https://minecraft.wiki/w/Java_Edition_level_format ; Java Edition 26.1, 26.2, 26.3, 26.4 ; 1.20.5 ; 1.21.9
- Server.properties: https://minecraft.wiki/w/Server.properties ; Server.jar ; Game rule ; Game mode ; Commands: /transfer, /save-off, /save-all, /defaultgamemode, /setworldspawn ; Spawn protection ; World seed ; World preset ; Dimension definition ; Tutorial:Adding a new dimension ; Superflat ; Permission level ; Minecraft Server Management Protocol ; Java Edition protocol/Packets ; Data version ; Player.dat format.
- Mojira reports referenced by search result only: MC-215960, MC-207625, MC-196653 (R).

**Fabric mods and libraries (Modrinth pages/API and GitHub READMEs; behavior claims R)**
- Fantasy: https://github.com/NucleoidMC/fantasy ; Maven https://maven.nucleoid.xyz
- Worlds: https://github.com/Wroud/mc-worlds ; World Manager: https://github.com/DrexHD/WorldManager ; Multiverse: https://github.com/senseiwells/Multiverse ; Multiworld: https://github.com/IsaiahMC/multiworld ; World Portal, Dimension Link (mahmudindev)
- Dimensional Inventories: https://github.com/Thomilist/dimensional-inventories
- FabricPlots: https://github.com/beachfury/fabricplots
- Open Parties and Claims: https://github.com/thexaero/open-parties-and-claims ; Flan: https://github.com/Flemmli97/Flan ; GOML-Reserved: https://github.com/Patbox/get-off-my-lawn-reserved
- Mirage Sync: https://github.com/MRNOBODY-ZST/Mirage ; ChunkSync, Creativerse, Seeded Dimensions (Modrinth pages)
- Ledger: QuiltServerTools/Ledger ; FastBack: pcal43/fastback ; Terralith and William Wythers' Overhauled Overworld (Modrinth)
- WorldEdit, LuckPerms, fabric-permissions-api, Vanilla Permissions, Essential Commands (Modrinth)

**Transfer, proxy, multi-instance**
- Velocity docs: https://docs.papermc.io/velocity/ ; repo https://github.com/PaperMC/Velocity ; builds https://fill.papermc.io/v3/projects/velocity
- FabricProxy-Lite: https://github.com/OKTW-Network/FabricProxy-Lite ; CrossStitch (Modrinth)
- Gate: https://github.com/minekube/gate ; mc-router: https://github.com/itzg/mc-router ; Infrared: https://github.com/haveachin/infrared
- PaperMC Aikar's flags (Paper-specific; used only for the host-RAM headroom statement): https://docs.papermc.io/paper/aikars-flags/
- systemd.resource-control and systemd.service man pages: https://www.freedesktop.org/software/systemd/man/latest/ ; kernel cgroup v2: https://docs.kernel.org/admin-guide/cgroup-v2.html
- Passage proxy security doc (secondary): https://passage.scrayos.net/overview/security/

**Project baseline (read directly):** `main.sh`, `src/common/setup.sh`, `src/setup/variables/set_server_properties.js`, `src/setup/management/create_service.sh`, `src/scripts/manage.sh`, `src/scripts/backup/backup.sh`, `restore.sh`, `src/scripts/world/lib/world.js`, `src/vanilla/download/*.txt`, `docs/GLOSSARY.md`.

---

## Appendix A. c2me-fabric (default performance mod in the suite)

Research date 2026-10-20, Minecraft 26.3 yardstick. Sources: Modrinth API (`c2me-fabric` project and versions), GitHub API and raw files for RelativityMC/C2ME-fabric branch `dev/26.3.0`, the project README, GitHub issue search, a search summary of Mojira MC-55596. Nothing was installed or run; no jar was inspected.

**What it is (V).** "Concurrent Chunk Management Engine (Fabric)", MIT on Modrinth (GitHub reports no SPDX match), Fabric only, server required and client optional, 41.3 million downloads, published 2021-10-02, last updated 2026-10-20. Repository: 820 stars, 25 open issues and PRs, pushed 2026-10-20, default branch `dev/26.3.0`, one branch per Minecraft version (including `dev/26.4.0`) plus backport branches for 1.21.1 and 1.21.11.

**Version track record (V, Modrinth).** Releases for 26.3, 26.2, 26.1.2, 1.21.11 and 1.21.1 within the last month; 26.3 builds `0.4.2-alpha.0.90` (2026-10-07), `.103`, `.104`, `.106` (2026-10-17); snapshot builds for 26.4 snapshots 3 to 5. **Every listed build is typed "alpha"** (version number `0.4.x-alpha.0.N`), and a new build appears every few days. The README states only the latest Minecraft release and latest snapshot are fully supported and older releases get critical fixes only. No dependencies are declared on the Modrinth versions read.

**What it changes (V from repository module names and config files; behavior R).** Modules: chunk system rewrite (async serialization, scheduling, POI unloading, ghost-mushroom workaround for MC-276863, fluid post-processing moved to scheduled ticks), chunk I/O with an NBT cache, scheduling, threading-fix modules, `opts-worldgen-vanilla` (aquifer and structure weight sampler optimizations), `opts-worldgen-general` (replacement random-source implementations), `opts-worldgen-biome-cache`, `opts-dfc` (a density function compiler that turns worldgen density functions into compiled code, with built-in integrations for other worldgen mods such as Lithostitched and Tectonic), `opts-natives-math` (native SIMD noise code, x86-64 and aarch64, loaded at runtime), an experimental OpenCL accelerator module, a "notickvd" module, and a client-side view-distance module. The config file is `c2me.toml`; the README benchmark section names `globalExecutorParallelism` as a setting.

**Vanilla parity claims (R; a README promise is not verified behavior).**
- README: C2ME "does not sacrifice vanilla functionality or behavior, or alter the vanilla world generation in the name of raw speed by default"; datapack worldgen that runs on vanilla is "fully supported"; custom generators in mods "usually run well" but "may" break.
- README on determinism: because of the non-determinism of vanilla generation (MC-55596), "worlds will vary significantly run-to-run even with the same seed. This is not a bug on our side." This is the project's own statement that same-seed results are not reproducible even without C2ME, and it applies equally to the suite's mirror premise.
- README: "bugs are unavoidable"; deviations from vanilla should be reported as issues. The README also says "Backup your worlds" (V text).
- Not found: any published test or statement that chunk output from C2ME's compiled density functions or native math is bit-identical to vanilla's. The repository contains a `tests` module with a pre-generation harness (file names only; its assertions were not read). Whether floating-point results from native SIMD noise or compiled density functions are byte-identical to the JVM implementation is not established.
- Some options carry their own warnings: `chunkSystem.recoverFromErrors` is off by default and its comment says it "will cause errored chunk to be regenerated entirely, which may cause data loss" (V text, source); `optimizeAquifer` and `optimizeStructureWeightSampler` declare incompatibilities with named mods (cavetweaks, porting_lib) (V text).

**Reported problems (R, GitHub issue search; counts are search totals, not a full audit).** A search for "corrupt world" returned 10 issues, all closed, including #580 (2026-08-04, crash on teleport and world corruption with a modpack, resolved by disabling seven config options), #568 (2026-06-29, world creation hangs with the OpenCL module enabled, leaving an incomplete world), #562 (2026-06-23, NeoForge 1.21.1 corrupted chunks), #460 (2025-07-25, fails to load chunks with old-format data) and #524 (conflict with another mod on 1.21.11). Searches for "structure mismatch seed" and "data loss" returned zero issues; #481 (2025-11-24, "unsafe world random access detected during entity spawn in worldgen") is the nearest to seed behavior. No issue titled as a seed mismatch versus vanilla was found. Issue bodies were not read.

**Interaction with the suite (V, project files).**
- `performance_mods.txt` lists `c2me-fabric` alongside `lithium`, `krypton` and others; the example config defaults `PERFORMANCE_MODS` to true, so Fabric setups install it by default.
- The suite's version selection (`versions.js`, `download_mods.js`) prefers a release, then a beta, then an alpha. Because C2ME publishes only alpha builds, the suite takes the newest alpha, and mod update checks will keep moving to newer alpha builds as they appear (a new build every few days in October 2026).
- A survival instance and a mirror instance set up at different times would each install whatever alpha was newest then (I), so the two can differ in C2ME build, which matters for any "identical" expectation.

**Findings relevant to the two capabilities.**
- Mirror (same seed): the realistic expectation set by the vanilla bug and by C2ME's own README is "same large-scale terrain, not guaranteed identical local details". C2ME adds a second, unmeasured source of difference (compiled and native noise code, replaced random implementations) that its README says it avoids by default. A server running C2ME and one without it are not shown to generate identically; the project claims no more than "no intentional change".
- World copy and sync: C2ME rewrites chunk I/O and serialization (async serializer, NBT cache). It writes the same world format (I; no format change was found), but whether `save-all flush` also flushes C2ME's asynchronous serialization is not verified (test below). Its `recoverFromErrors` option can regenerate errored chunks, which would silently replace data if enabled (off by default).
- Multi-world: chunk-system changes may interact with runtime-created dimensions (Fantasy-based mods); no compatibility statement for Worlds, Multiverse, World Manager or Multiworld was read.
- Maintenance and risk: very active and widely used, but alpha-labelled, tied to the newest Minecraft release and snapshot, with long-term support only for critical fixes on older versions. Cost per Minecraft bump: wait for a build, accept an alpha. Behavior differs by build.

**Open questions specific to C2ME (and the test or source that would settle each).**
1. Does C2ME change generated terrain relative to vanilla on 26.3 with the same seed? Test: generate the same area with and without C2ME on throwaway servers (single-threaded, fixed visiting order) and diff region files; repeat vanilla twice to establish the MC-55596 noise floor; repeat with the density function compiler, native math and aquifer/structure-weight options off. Source: the `tests` module and CI for parity tests.
2. Does `save-all flush` flush C2ME's async serializer, so that a `save-off` copy is consistent? Test: write blocks, run `save-all flush` and `save-off`, copy the world while chunks are loading, restart on the copy and look for missing or corrupted chunks. Source: C2ME `chunkio` and chunk-serializer code.
3. Does MC-55596 reproduce on 26.3 without mods? Test: the Mojira reproduction seed and coordinates with different visiting orders.
4. What are the real defaults in `c2me.toml` on 26.3 (the generated file was not read)? Source: the file generated on first run, or the `ConfigSystem` default values.
5. Does the OpenCL accelerator ever activate by default? Source: the module's config defaults (not read); the README links a separate experimental mod, which suggests it is not part of the default build.
6. Is a particular alpha build ever withdrawn or marked bad? Source: Modrinth version history and GitHub issues for rolled-back builds.
