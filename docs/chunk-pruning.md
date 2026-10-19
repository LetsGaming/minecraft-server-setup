# Chunk pruning

`src/scripts/world/prune-chunks.js` deletes generated chunks nobody has used, so
the next Minecraft version's world generation fills that space with new terrain,
biomes and structures. It is optional and does nothing until it is run.

## What counts as unused

A chunk is a deletion candidate when its `InhabitedTime` (the ticks a player spent
near it) is below a threshold (default 5 minutes). These are never deleted, whatever
the threshold:

- chunks around the world spawn (default 16 chunks) and around where each player was
  last seen or respawns (default 8), read from `level.dat` and `playerdata/` (`players/data/`
  from 26.x), including the respawn fields of both the older and the 1.21.5 layout;
- chunks kept loaded with `/forceload`, read per dimension from `<dimension>/data/chunks.dat`
  (the packed `Forced` list, or ticket entries with a `chunk_pos`). Where that file exists but
  cannot be read, the plan carries `forced_chunks_unreadable`; a player file that cannot be read
  adds `player_files_unreadable`. The layout of forced chunks in 26.x worlds could not be checked
  against a real world, so only these two spellings are recognised;
- zones you draw, per dimension, in chunk coordinates;
- chunks that cannot be read, or have no `InhabitedTime` (corrupt, LZ4-compressed,
  or from a layout this does not know);
- a buffer of N chunks (default 2) around everything that stays, so a build does not
  end at a seam of fresh terrain.

Region, entities and poi folders are pruned together, so no entity or point of
interest is left pointing at a chunk that no longer exists. Dimensions are discovered
(overworld, `DIM-1`, `DIM1`, and `dimensions/<namespace>/<name>`), not assumed.

## Build protection

With `params.buildProtection` at `likely` (the default) a chunk the rules would delete is kept as
**uncertain** (cell class 8, counted as `uncertain`) when it holds block entities that nothing
natural explains: chests, barrels, signs, furnaces, beds, hoppers or any modded block entity, in a
chunk with no generated structure (start or reference) and no spawner. Villages, mineshafts and
ruins hold such blocks by themselves, and a dungeon is a spawner and a chest, so those do not count.
It keeps data where a player may have built, and acts like the buffer: a manual selection may still
choose such a chunk. It is advisory and can be wrong in both directions, which is why it only ever
keeps a chunk. `off` ignores what chunks contain and is cheaper to scan; the record cache keeps
records read with and without these signals apart. Only 1.18 and newer chunks carry the tags it reads.

`--inspect --plan=<id> --dimension=<id> --cx=<n> --cz=<n>` reads one chunk in full and reports its
status, data version, time in use, size on disk, block entities by id, structure starts and
references, the signals above, whether it is in the plan, and which protections (spawn, player,
named zone) cover it.

## Terrain tiles

`--tile --dimension=<id> --rx=<n> --rz=<n>` draws one region from above as a 512 x 512 PNG, one
pixel per block, for the dashboard's terrain view. Each column is the top block of the
`WORLD_SURFACE` height map, looked up in the section's packed palette, coloured from a table
(`world/lib/blockColors.js`: common blocks, shapes of a material, dye families, a neutral grey for
modded or new blocks), water darker the deeper it is, and a hint of relief against the column to the
north. There is no biome tint and no shading beyond that: it is for orientation, not a renderer.
Tiles are written under `common/prune/tiles/<dimension>/r.<x>.<z>.<fingerprint>.png`; the region
file's fingerprint is part of the name, so an edited region can never show an old picture, and the
folder is trimmed oldest first past 500 MB. Chunks that cannot be read, or that predate the 1.18
layout, are left transparent. `tests/bench/render-tile.cjs` draws one region of a real world to a file
so you can look at it.

## Choosing chunks by hand

`params.selection` is an ordered list of rectangles in chunk coordinates (at most 2,500):

```json
{ "selection": { "ops": [
  { "dimension": "overworld", "mode": "add",    "x1": 0, "z1": 0, "x2": 40, "z2": 40 },
  { "dimension": "overworld", "mode": "remove", "x1": 10, "z1": 10, "x2": 12, "z2": 12 }
], "allowProtected": false } }
```

Later operations win. A chunk chosen this way is deleted even where a **soft rule** would keep
it (in use, buffer). A **hard protection** (spawn, player areas, drawn zones) holds unless
`allowProtected` is true. An unreadable chunk is never deleted, whatever the selection says,
because it cannot be verified. The result is exact and authoritative, since it is computed by
the same scan: per dimension the summary reports `manualSoft` and `manualHard` (parts of
`delete`) and `manualBlocked` (chosen but kept). On the map these chunks are cell classes 6
and 7. The selection is part of the plan and its hash, and is never saved as a default.

## Choosing dimensions

`params.dimensions` limits everything to the named dimensions: only their region files are
read, cached and pruned. `--dimensions` lists what a world has (names and region-file counts)
from directory listings, without reading a chunk.

## Modes

```
node prune-chunks.js --dimensions                 names and region counts, reads no chunk
node prune-chunks.js --scan [--params=<json> | --params-file=<path> | --params-stdin]
node prune-chunks.js --apply --plan=<id> --backup=<archive> [--allow-unknown-spawn] [--time-budget=<seconds>]
node prune-chunks.js --settings=get | set --params=<json>
node prune-chunks.js --status                     engine version, an unfinished delete
```

`--scan` is safe on a running server; its answer is approximate because region files
can be mid-write. A plan lives under `common/prune/` (the newest five are kept) with
a map per dimension for the dashboard.

Reading is done by worker threads (`--workers=<n>`, default the core count minus one, at most
4) into a per-region record cache under `common/prune/cache/`. A record depends only on the
region file and is reused while its size, modification time and header digest are unchanged,
so a repeat scan reads only changed regions and a different threshold, radius, buffer or zone
needs no file I/O at all. `--no-cache` forces a full read. Progress is printed as NDJSON
lines (`phase: "scan"`, `done`, `total`, `chunks`, `etaSeconds`); a scan can be cancelled by
stopping the process, because it only reads and every cache write is atomic. The buffer is
decided per region with a halo from its neighbours, so a far-away region cannot fail the scan.

`--apply` needs a backup behind it and names it: `--backup=<archive>` (or `MC_PRUNE_BACKUP`), a
non-empty `.tar.zst` or `.tar.gz` inside the backups folder that is at most a day old. The script
checks the file; a flag alone proves nothing. The upgrade job takes its own archive backup first
and passes that. A plan made while `level.dat` was unreadable carries `spawn_unknown` (the spawn
protection was a guess at the origin) and is refused with that code unless `--allow-unknown-spawn`
is given. An unfinished apply is remembered in `common/prune/prune-apply.journal` until a later
apply finishes; a new apply keeps the earlier note inside its own, and one refused before it
deletes anything puts the earlier note back as it was.

`--apply` refuses to run while the server is up. It scans again and deletes only what
both scans agree on, so a preview made while players were online can remove less than
it promised and never more. If fewer than 90 % of the planned chunks are still unused
it deletes nothing and reports `plan_stale`. Each rewritten region file is compacted
(the space really comes back), written beside the original and renamed over it, and
every chunk kept in it is compared byte for byte with what was copied before the job counts
as done. A chunk that was already unreadable is kept as it was. A region file whose header
cannot be trusted (a chunk with no sectors, or two chunks sharing sectors) is left untouched
and reported as skipped. The plan must match its own hash, and the folder to delete in comes
from the fresh scan, never from the stored plan. Without `common/instance_ops.sh` the
server counts as running and `--apply` refuses; a hand-run `--apply` takes the operation lock.

While a delete runs it writes `common/prune/prune-apply.journal` (`applying`); a clean finish
removes it, a failed one leaves it as `failed`, and a process that died leaves it as `applying`.
`--status` reports it as `unfinishedApply`, because the world may then be half pruned and the
job's backup is the way back. `--apply` stops itself after `--time-budget` seconds (default
45 minutes) and reports `time_budget`, so the orchestrator rolls back instead of being killed
in the middle of a delete. Entities and poi files are rewritten before the region file, each
through a flushed temporary file and a rename, and temporary files left by an interrupted run
are removed on the next one.

`--scan --profile` adds phase timings, counts and peak memory to the summary. It reads single-threaded and without the cache, so the numbers are the plain cost of a scan.
`tests/bench/bench-prune.cjs` builds a synthetic world (or scans a real one, read only)
and prints the same numbers; see `docs/prune-benchmarks.md`.

## Run it safely

Take a backup first. `upgrade.sh <version> --prune-plan=<id>` runs the prune after the
install and before the first start of the new version, under the upgrade's single
backup, so a failed prune rolls the whole upgrade back. `upgrade.sh --prune-only
--prune-plan=<id>` is the same job without a version change. Run by hand, take your
own backup and stop the server.

## Engine

The reader and writer are built in (Node, no dependencies). The functions in
`world/lib/plan.js` are the whole interface (`scanWorld`, `applyPlan`); another engine,
such as MCA Selector's command line, can replace them without touching the wrapper
routes or the dashboard. LZ4-compressed chunks (1.20.5+ `region-file-compression`) are
kept, never deleted, until a decoder is added. MCA Selector's command line was evaluated and
not adopted: it returns no per-chunk data or progress, always exits 0, writes non-atomically,
needs Java 21 and a display for its image modes, and the dashboard needs the data it cannot
give. The records and cell classes above are what the map and the selection are built on.
