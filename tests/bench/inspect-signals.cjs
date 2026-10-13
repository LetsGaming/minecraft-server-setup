"use strict";

/**
 * What build protection keeps, and why.
 *
 *   node tests/bench/inspect-signals.cjs --world=/path/to/server [--regions=150] [--threshold=5]
 *
 * Reads a spread of region files (read only), and for the chunks the rules would delete
 * (InhabitedTime below the threshold) reports how many hold block entities that no structure
 * explains, and which block entity ids they are. Use it to see whether the "looks built"
 * class is catching builds or something natural that should be recognised. Prints one JSON object.
 */

const fs = require("fs");
const path = require("path");

const region = require("../../src/scripts/world/lib/region.js");
const world = require("../../src/scripts/world/lib/world.js");
const { chunkSignalsFast, parseNbt, SIGNAL } = require("../../src/scripts/world/lib/nbt.js");
const { isUnexplained } = require("../../src/scripts/world/lib/plan.js");

function arg(name, fallback) {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
}

const serverPath = arg("world", null);
const wantedRegions = Number(arg("regions", 150));
const thresholdTicks = Number(arg("threshold", 5)) * 1200;
if (!serverPath) {
  console.error("Usage: node tests/bench/inspect-signals.cjs --world=<server path> [--regions=150] [--threshold=5]");
  process.exit(64);
}

const files = [];
for (const dim of world.discoverDimensions(world.worldDirOf(serverPath))) {
  const dir = path.join(dim.dir, "region");
  let names = [];
  try {
    names = fs.readdirSync(dir);
  } catch {
    continue;
  }
  for (const name of names) if (region.parseRegionName(name)) files.push({ dim: dim.id, file: path.join(dir, name) });
}
const step = Math.max(1, Math.floor(files.length / wantedRegions));
const picked = files.filter((_, i) => i % step === 0).slice(0, wantedRegions);

const t = {
  regions: picked.length,
  chunks: 0,
  unused: 0,
  unexplained: 0,
  withStructure: 0,
  withSpawner: 0,
  notFull: 0,
};
const ids = new Map();
const idsAlone = new Map();
const perDimension = new Map();
const examples = [];

for (const { dim, file } of picked) {
  const buf = fs.readFileSync(file);
  const header = region.readHeader(buf);
  if (!header) continue;
  for (const slot of region.occupiedSlots(header)) {
    const res = region.readChunk(buf, header, slot, path.dirname(file), 0, 0);
    if (!res.ok) continue;
    let s;
    try {
      s = chunkSignalsFast(res.data);
    } catch {
      continue;
    }
    t.chunks++;
    if (typeof s.inhabited !== "number" || s.inhabited >= thresholdTicks) continue;
    t.unused++;
    if (s.flags & SIGNAL.NOT_FULL) t.notFull++;
    if (s.flags & (SIGNAL.STRUCTURE_START | SIGNAL.STRUCTURE_REFERENCE)) t.withStructure++;
    if (s.flags & SIGNAL.SPAWNER) t.withSpawner++;
    if (!isUnexplained(s.flags)) continue;
    t.unexplained++;
    perDimension.set(dim, (perDimension.get(dim) ?? 0) + 1);
    let nbt;
    try {
      nbt = parseNbt(res.data);
    } catch {
      continue;
    }
    const list = (Array.isArray(nbt.block_entities) ? nbt.block_entities : []).map((b) => (typeof b?.id === "string" ? b.id.replace("minecraft:", "") : "?"));
    for (const id of new Set(list)) ids.set(id, (ids.get(id) ?? 0) + 1);
    if (new Set(list).size === 1) idsAlone.set(list[0], (idsAlone.get(list[0]) ?? 0) + 1);
    if (examples.length < 8) examples.push({ dim, file: path.basename(file), slot, ids: [...new Set(list)], minutes: Math.round((s.inhabited / 1200) * 10) / 10 });
  }
}

const top = (m, n = 15) => [...m].sort((a, b) => b[1] - a[1]).slice(0, n).map(([id, chunks]) => ({ id, chunks }));
process.stdout.write(
  JSON.stringify(
    {
      ...t,
      unexplainedShareOfUnused: t.unused ? Math.round((t.unexplained / t.unused) * 1000) / 10 : 0,
      byDimension: Object.fromEntries(perDimension),
      blockEntityIdsInUnexplainedChunks: top(ids),
      chunksWhereThatIsTheOnlyId: top(idsAlone),
      examples,
    },
    null,
    2,
  ) + "\n",
);
