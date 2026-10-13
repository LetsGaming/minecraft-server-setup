"use strict";

/**
 * What real chunks look like to the scan, to decide where the next speedup is.
 *
 *   node tests/bench/inspect-chunks.cjs --world=/path/to/server [--sample=400]
 *
 * Reads a random sample of chunks (read only) and reports their sizes, how long
 * the old and the fast InhabitedTime walk take, where InhabitedTime sits in the
 * inflated document, and how much of the compressed payload a partial inflate
 * needs before it appears. Prints one JSON object.
 */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const region = require("../../src/scripts/world/lib/region.js");
const world = require("../../src/scripts/world/lib/world.js");
const { chunkMeta, inhabitedTime } = require("../../src/scripts/world/lib/nbt.js");

function arg(name, fallback) {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
}

const serverPath = arg("world", null);
const sample = Number(arg("sample", 400));
if (!serverPath) {
  console.error("Usage: node tests/bench/inspect-chunks.cjs --world=<server path> [--sample=400]");
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
  for (const name of names) {
    const parsed = region.parseRegionName(name);
    if (parsed) files.push({ file: path.join(dir, name), ...parsed });
  }
}
if (files.length === 0) {
  console.error("No region files found.");
  process.exit(1);
}

const INHABITED = Buffer.from("InhabitedTime");
const stats = { chunks: 0, compressed: 0, inflated: 0, inflateMs: 0, metaMs: 0, fastMs: 0, offsetFraction: [], prefixFraction: [], notFoundInPrefix: 0 };
const perFile = Math.max(1, Math.ceil(sample / Math.min(files.length, 50)));

for (let i = 0; i < Math.min(files.length, 50) && stats.chunks < sample; i++) {
  const f = files[Math.floor((i * files.length) / Math.min(files.length, 50))];
  const buf = fs.readFileSync(f.file);
  const header = region.readHeader(buf);
  if (!header) continue;
  const slots = region.occupiedSlots(header);
  for (let n = 0; n < Math.min(perFile, slots.length); n++) {
    const slot = slots[Math.floor((n * slots.length) / Math.min(perFile, slots.length))];
    const loc = header.locations[slot];
    const start = region.sectorOffset(loc) * region.SECTOR;
    if (start + 5 > buf.length) continue;
    const length = buf.readUInt32BE(start);
    const compression = buf[start + 4];
    if (compression !== 2 || start + 4 + length > buf.length) continue;
    const payload = buf.subarray(start + 5, start + 4 + length);

    let t0 = process.hrtime.bigint();
    const data = zlib.inflateSync(payload);
    stats.inflateMs += Number(process.hrtime.bigint() - t0) / 1e6;
    t0 = process.hrtime.bigint();
    chunkMeta(data);
    stats.metaMs += Number(process.hrtime.bigint() - t0) / 1e6;
    t0 = process.hrtime.bigint();
    inhabitedTime(data);
    stats.fastMs += Number(process.hrtime.bigint() - t0) / 1e6;

    const at = data.indexOf(INHABITED);
    if (at >= 0) stats.offsetFraction.push(at / data.length);

    // Smallest compressed prefix (multiples of 1/16) whose partial inflate contains the tag.
    let found = false;
    for (let k = 1; k <= 16; k++) {
      const cut = Math.ceil((payload.length * k) / 16);
      try {
        const part = zlib.inflateSync(payload.subarray(0, cut), { finishFlush: zlib.constants.Z_SYNC_FLUSH });
        if (part.indexOf(INHABITED) >= 0) {
          stats.prefixFraction.push(k / 16);
          found = true;
          break;
        }
      } catch {
        /* a cut in the middle of a block can fail; try a longer prefix */
      }
    }
    if (!found) stats.notFoundInPrefix++;

    stats.chunks++;
    stats.compressed += payload.length;
    stats.inflated += data.length;
  }
}

const avg = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);
const pct = (a, p) => (a.length ? [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))] : null);
const round = (v, d = 3) => (v === null ? null : Number(v.toFixed(d)));

process.stdout.write(
  JSON.stringify(
    {
      regionFiles: files.length,
      sampled: stats.chunks,
      avgCompressedBytes: Math.round(stats.compressed / stats.chunks),
      avgInflatedBytes: Math.round(stats.inflated / stats.chunks),
      inflateUsPerChunk: round((stats.inflateMs / stats.chunks) * 1000, 1),
      oldWalkUsPerChunk: round((stats.metaMs / stats.chunks) * 1000, 1),
      fastWalkUsPerChunk: round((stats.fastMs / stats.chunks) * 1000, 1),
      inhabitedOffsetFractionOfDocument: { avg: round(avg(stats.offsetFraction)), p50: round(pct(stats.offsetFraction, 0.5)), p95: round(pct(stats.offsetFraction, 0.95)) },
      compressedPrefixNeeded: { avg: round(avg(stats.prefixFraction)), p50: round(pct(stats.prefixFraction, 0.5)), p95: round(pct(stats.prefixFraction, 0.95)), notFound: stats.notFoundInPrefix },
    },
    null,
    2,
  ) + "\n",
);
