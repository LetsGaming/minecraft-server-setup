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

`--apply` refuses to run while the server is up. It scans again and deletes only what
both scans agree on, so a preview made while players were online can remove less than
it promised and never more. If fewer than 90 % of the planned chunks are still unused
it deletes nothing and reports `plan_stale`. Each rewritten region file is compacted
(the space really comes back), written beside the original and renamed over it, and
every chunk left in it is read back before the job counts as done.

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
