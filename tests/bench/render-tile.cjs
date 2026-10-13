"use strict";

/**
 * Draw one region from above, to look at it.
 *
 *   node tests/bench/render-tile.cjs --world=/path/to/server [--dimension=overworld] [--rx=0 --rz=0] [--out=tile.png]
 *
 * Without --rx and --rz it picks the region file with the most chunks in the dimension. Reads
 * only, writes the PNG to --out (default ./tile-<dimension>-<rx>-<rz>.png) and prints how long it took.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");

const region = require("../../src/scripts/world/lib/region.js");
const world = require("../../src/scripts/world/lib/world.js");
const tiles = require("../../src/scripts/world/lib/tiles.js");

const arg = (name, fallback) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
};

const serverPath = arg("world", null);
if (!serverPath) {
  console.error("Usage: node tests/bench/render-tile.cjs --world=<server path> [--dimension=overworld] [--rx=<n> --rz=<n>] [--out=<file>]");
  process.exit(64);
}
const dimension = arg("dimension", "overworld");
const dim = world.discoverDimensions(world.worldDirOf(serverPath)).find((d) => d.id === dimension);
if (!dim) {
  console.error(`No dimension ${dimension}.`);
  process.exit(1);
}

let rx = arg("rx", null);
let rz = arg("rz", null);
if (rx === null || rz === null) {
  const dir = path.join(dim.dir, "region");
  let best = null;
  for (const name of fs.readdirSync(dir)) {
    const parsed = region.parseRegionName(name);
    if (!parsed) continue;
    const size = fs.statSync(path.join(dir, name)).size;
    if (!best || size > best.size) best = { ...parsed, size };
  }
  if (!best) {
    console.error("No region files.");
    process.exit(1);
  }
  rx = best.x;
  rz = best.z;
}
rx = Number(rx);
rz = Number(rz);

const tilesDir = fs.mkdtempSync(path.join(os.tmpdir(), "render-tile-"));
const t0 = Date.now();
const tile = tiles.tileFor({ serverPath, dimension, rx, rz, tilesDir });
const ms = Date.now() - t0;
if (!tile) {
  console.error("No such region.");
  process.exit(1);
}
const out = arg("out", `tile-${dimension}-${rx}-${rz}.png`);
fs.copyFileSync(tile.file, out);
fs.rmSync(tilesDir, { recursive: true, force: true });
process.stdout.write(JSON.stringify({ dimension, rx, rz, chunksDrawn: tile.chunks, pngBytes: tile.bytes, ms, out: path.resolve(out) }, null, 2) + "
");
