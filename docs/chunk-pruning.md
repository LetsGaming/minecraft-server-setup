# Chunk pruning

`src/scripts/world/prune-chunks.js` deletes generated chunks nobody has used, so
the next Minecraft version's world generation fills that space with new terrain,
biomes and structures. It is optional and does nothing until it is run.

## What counts as unused

A chunk is a deletion candidate when its `InhabitedTime` (the ticks a player spent
near it) is below a threshold (default 5 minutes). These are never deleted, whatever
the threshold:

- chunks around the world spawn (default 16 chunks) and around where each player was
  last seen (default 8), read from `level.dat` and `playerdata/`;
- zones you draw, per dimension, in chunk coordinates;
- chunks that cannot be read, or have no `InhabitedTime` (corrupt, LZ4-compressed,
  or from a layout this does not know);
- a buffer of N chunks (default 2) around everything that stays, so a build does not
  end at a seam of fresh terrain.

Region, entities and poi folders are pruned together, so no entity or point of
interest is left pointing at a chunk that no longer exists. Dimensions are discovered
(overworld, `DIM-1`, `DIM1`, and `dimensions/<namespace>/<name>`), not assumed.

## Modes

```
node prune-chunks.js --scan [--params=<json>]     read only, stores a plan
node prune-chunks.js --apply --plan=<id>          delete what the plan names
node prune-chunks.js --settings=get | set --params=<json>
node prune-chunks.js --status
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
kept, never deleted, until a decoder is added.
