const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { chunkMeta } = require("../../src/scripts/world/lib/nbt.js");
const region = require("../../src/scripts/world/lib/region.js");
const world = require("../../src/scripts/world/lib/world.js");
const plan = require("../../src/scripts/world/lib/plan.js");
const fx = require("./worldFixtures.cjs");

const MIN = plan.TICKS_PER_MINUTE;

function withServer(fn, opts) {
  return () => {
    const server = fx.makeServer(opts);
    try {
      fn(server);
    } finally {
      server.cleanup();
    }
  };
}

const chunk = (x, z, minutes, extra = {}) => ({ x, z, nbt: fx.chunkModern({ x, z, inhabited: minutes * MIN }), ...extra });

// ── NBT ──

test("chunkMeta reads the flat 1.18 layout and skips everything else", () => {
  const meta = chunkMeta(fx.chunkModern({ x: 3, z: -4, inhabited: 2400, padding: 500 }));
  assert.equal(meta.InhabitedTime, 2400);
  assert.equal(meta.xPos, 3);
  assert.equal(meta.zPos, -4);
  assert.equal(meta.Status, "minecraft:full");
  assert.equal(meta.DataVersion, 3955);
});

test("chunkMeta reads the pre-1.18 Level layout", () => {
  const meta = chunkMeta(fx.chunkLegacy({ x: 1, z: 2, inhabited: 99 }));
  assert.equal(meta.InhabitedTime, 99);
  assert.equal(meta.xPos, 1);
});

test("chunkMeta rejects a document that is not a compound", () => {
  assert.throws(() => chunkMeta(Buffer.from([9, 0, 0])), /not a compound/);
  assert.throws(() => chunkMeta(Buffer.from([10, 0, 0, 1])), /ended early/);
});

// ── Region files ──

test(
  "reading a region returns each chunk and names the ones it cannot read",
  withServer((s) => {
    const file = s.regionFile(null, "region", 0, 0);
    fx.writeRegion(file, 0, 0, [
      chunk(0, 0, 10),
      { ...chunk(1, 0, 10), compression: "gzip" },
      { ...chunk(2, 0, 10), compression: "none" },
      { ...chunk(3, 0, 10), compression: "lz4" },
      { ...chunk(4, 0, 10), compression: "corrupt" },
    ]);
    const buf = fs.readFileSync(file);
    const header = region.readHeader(buf);
    assert.deepEqual(region.occupiedSlots(header), [0, 1, 2, 3, 4]);
    for (const slot of [0, 1, 2]) {
      assert.equal(region.readChunk(buf, header, slot, path.dirname(file), 0, 0).ok, true);
    }
    assert.equal(region.readChunk(buf, header, 3, path.dirname(file), 0, 0).reason, "lz4");
    assert.equal(region.readChunk(buf, header, 4, path.dirname(file), 0, 0).reason, "corrupt");
    assert.equal(region.readChunk(buf, header, 9, path.dirname(file), 0, 0).reason, "empty");
  }),
);

test(
  "removing chunks compacts the file and leaves the rest byte for byte",
  withServer((s) => {
    const file = s.regionFile(null, "region", 0, 0);
    fx.writeRegion(file, 0, 0, [chunk(0, 0, 1), chunk(1, 0, 100), chunk(2, 0, 1)]);
    const before = fs.readFileSync(file);
    const h = region.readHeader(before);
    const keptBefore = before.subarray(region.sectorOffset(h.locations[1]) * 4096, (region.sectorOffset(h.locations[1]) + region.sectorCount(h.locations[1])) * 4096);

    const res = region.removeChunks(file, [0, 2]);
    assert.equal(res.kept, 1);
    assert.equal(res.removed, 2);
    assert.ok(res.bytesAfter < res.bytesBefore);

    const after = fs.readFileSync(file);
    const h2 = region.readHeader(after);
    assert.deepEqual(region.occupiedSlots(h2), [1]);
    const at = region.sectorOffset(h2.locations[1]) * 4096;
    assert.deepEqual(after.subarray(at, at + keptBefore.length), keptBefore);
    assert.equal(h2.timestamps[1], h.timestamps[1], "the chunk keeps its timestamp");
    assert.equal(fs.readdirSync(path.dirname(file)).filter((n) => n.endsWith(".tmp")).length, 0);
  }),
);

test(
  "removing every chunk reports an empty region and writes nothing",
  withServer((s) => {
    const file = s.regionFile(null, "region", 0, 0);
    fx.writeRegion(file, 0, 0, [chunk(0, 0, 1)]);
    const before = fs.readFileSync(file);
    const res = region.removeChunks(file, [0]);
    assert.equal(res.kept, 0);
    assert.deepEqual(fs.readFileSync(file), before, "the caller decides to delete the file");
  }),
);

// ── World ──

test(
  "dimensions are discovered, including datapack ones, and need a region folder",
  withServer((s) => {
    fx.writeRegion(s.regionFile(s.worldDir, "region", 0, 0), 0, 0, [chunk(0, 0, 1)]);
    fx.writeRegion(path.join(s.worldDir, "DIM-1", "region", "r.0.0.mca"), 0, 0, [chunk(0, 0, 1)]);
    fs.mkdirSync(path.join(s.worldDir, "DIM1"), { recursive: true });
    fx.writeRegion(path.join(s.worldDir, "dimensions", "mymod", "caves", "region", "r.0.0.mca"), 0, 0, [chunk(0, 0, 1)]);
    const ids = world.discoverDimensions(s.worldDir).map((d) => d.id);
    assert.deepEqual(ids, ["overworld", "the_nether", "mymod:caves"]);
  }),
);

test(
  "level-name picks the world folder and may not be a path",
  withServer((s) => {
    assert.equal(path.basename(world.worldDirOf(s.dir)), "survival");
    fs.writeFileSync(path.join(s.dir, "server.properties"), "level-name=../etc\n");
    assert.throws(() => world.worldDirOf(s.dir), /plain folder name/);
  }, { levelName: "survival" }),
);

test(
  "spawn and player positions are read from level.dat and playerdata",
  withServer((s) => {
    fx.writeLevelDat(s.worldDir, 160, -320);
    fx.writePlayer(s.worldDir, "aaaa", { x: 100.5, z: 200.5 });
    fx.writePlayer(s.worldDir, "bbbb", { dimension: "minecraft:the_nether", x: 8, z: 8 });
    assert.deepEqual(world.readSpawn(s.worldDir), { x: 160, z: -320 });
    const players = world.readPlayerPositions(s.worldDir);
    assert.equal(players.length, 2);
    assert.ok(players.some((p) => p.dimension === "the_nether"));
    fs.writeFileSync(path.join(s.worldDir, "playerdata", "broken.dat"), "garbage");
    assert.equal(world.readPlayerPositions(s.worldDir).length, 2, "an unreadable player file is skipped");
  }),
);

// ── Scan ──

/** A 4x1 strip: chunk 0 and 1 unused, 2 busy, 3 unused, far from spawn. */
function strip(s, minutes) {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  fx.writeRegion(
    s.regionFile(null, "region", 0, 0),
    0,
    0,
    minutes.map((m, i) => chunk(i, 0, m)),
  );
}

const cellsOf = (result, dimId = "overworld", key = "r.0.0") => {
  const dim = result.plan.dimensions.find((d) => d.id === dimId);
  const cell = Buffer.from(result.maps[dimId].regions[key].cell, "base64");
  return { dim, cell };
};

test(
  "chunks below the threshold are deleted, busy ones kept",
  withServer((s) => {
    strip(s, [0, 2, 60, 1]);
    const r = plan.scanWorld({ serverPath: s.dir, params: { thresholdMinutes: 5, bufferChunks: 0, spawnRadiusChunks: 0, playerRadiusChunks: 0 } });
    const { dim, cell } = cellsOf(r);
    assert.deepEqual([...cell.subarray(0, 4)], [plan.CELL.DELETE, plan.CELL.DELETE, plan.CELL.ACTIVE, plan.CELL.DELETE]);
    assert.equal(dim.delete, 3);
    assert.equal(dim.active, 1);
    assert.equal(r.plan.totals.delete, 3);
    assert.ok(r.plan.totals.bytes > 0);
  }),
);

test(
  "the buffer keeps chunks next to what stays",
  withServer((s) => {
    strip(s, [0, 0, 0, 0, 60, 0, 0, 0, 0]);
    const r = plan.scanWorld({ serverPath: s.dir, params: { thresholdMinutes: 5, bufferChunks: 2, spawnRadiusChunks: 0, playerRadiusChunks: 0 } });
    const { cell } = cellsOf(r);
    assert.deepEqual(
      [...cell.subarray(0, 9)],
      [1, 1, 4, 4, 2, 4, 4, 1, 1].map((n) => n),
      "two chunks each side of the busy one are buffer, the rest deleted",
    );
  }),
);

test(
  "the buffer crosses a region border",
  withServer((s) => {
    fx.writeLevelDat(s.worldDir, 100_000, 100_000);
    fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [chunk(31, 0, 0), chunk(30, 0, 0)]);
    fx.writeRegion(s.regionFile(null, "region", 1, 0), 1, 0, [chunk(32, 0, 60)]);
    const r = plan.scanWorld({ serverPath: s.dir, params: { thresholdMinutes: 5, bufferChunks: 1, spawnRadiusChunks: 0, playerRadiusChunks: 0 } });
    const west = cellsOf(r, "overworld", "r.0.0").cell;
    assert.equal(west[31], plan.CELL.BUFFER, "next to the busy chunk across the border");
    assert.equal(west[30], plan.CELL.DELETE, "one further is free");
  }),
);

test(
  "spawn, players and zones are protected",
  withServer((s) => {
    fx.writeLevelDat(s.worldDir, 0, 0);
    fx.writePlayer(s.worldDir, "aaaa", { x: 16 * 20 + 8, z: 8 });
    fx.writeRegion(
      s.regionFile(null, "region", 0, 0),
      0,
      0,
      [0, 1, 10, 20, 25, 28].map((x) => chunk(x, 0, 0)),
    );
    const r = plan.scanWorld({
      serverPath: s.dir,
      params: {
        thresholdMinutes: 5,
        bufferChunks: 0,
        spawnRadiusChunks: 2,
        playerRadiusChunks: 1,
        zones: [{ dimension: "overworld", x1: 28, z1: 0, x2: 28, z2: 0, name: "base" }],
      },
    });
    const { cell } = cellsOf(r);
    const at = (x) => cell[x];
    assert.equal(at(0), plan.CELL.PROTECTED, "spawn");
    assert.equal(at(1), plan.CELL.PROTECTED, "spawn");
    assert.equal(at(10), plan.CELL.DELETE, "unprotected");
    assert.equal(at(20), plan.CELL.PROTECTED, "a player's chunk");
    assert.equal(at(25), plan.CELL.DELETE, "outside the player's radius");
    assert.equal(at(28), plan.CELL.PROTECTED, "a drawn zone");
  }),
);

test(
  "a chunk that cannot be read, or has no InhabitedTime, is never a deletion",
  withServer((s) => {
    strip(s, [0]);
    fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [
      chunk(0, 0, 0),
      { ...chunk(1, 0, 0), compression: "lz4" },
      { ...chunk(2, 0, 0), compression: "corrupt" },
      { x: 3, z: 0, nbt: fx.chunkModern({ x: 3, z: 0, inhabited: 0 }).subarray(0, 20) },
    ]);
    const r = plan.scanWorld({ serverPath: s.dir, params: { bufferChunks: 0, spawnRadiusChunks: 0, playerRadiusChunks: 0 } });
    const { cell, dim } = cellsOf(r);
    assert.deepEqual([...cell.subarray(0, 4)], [plan.CELL.DELETE, 5, 5, 5]);
    assert.equal(dim.unreadable, 3);
  }),
);

test(
  "an unknown spawn is reported rather than guessed silently",
  withServer((s) => {
    fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [chunk(0, 0, 0)]);
    const r = plan.scanWorld({ serverPath: s.dir, params: {} });
    assert.ok(r.plan.warnings.includes("spawn_unknown"));
  }),
);

test(
  "the plan id depends on what would be deleted, not on when",
  withServer((s) => {
    strip(s, [0, 0, 60]);
    const a = plan.scanWorld({ serverPath: s.dir, params: { bufferChunks: 0 } });
    const b = plan.scanWorld({ serverPath: s.dir, params: { bufferChunks: 0 } });
    assert.equal(a.plan.id, b.plan.id);
    const c = plan.scanWorld({ serverPath: s.dir, params: { bufferChunks: 0, thresholdMinutes: 100 } });
    assert.notEqual(a.plan.id, c.plan.id);
  }),
);

test("parameters are clamped and zones are normalised", () => {
  const p = plan.normalizeParams({
    thresholdMinutes: -5,
    bufferChunks: 9999,
    zones: [{ dimension: "overworld", x1: 5, z1: 5, x2: 1, z2: 1 }, { dimension: 3 }],
  });
  assert.equal(p.thresholdMinutes, 0);
  assert.equal(p.bufferChunks, 32);
  assert.deepEqual(p.zones, [{ name: "", dimension: "overworld", x1: 1, z1: 1, x2: 5, z2: 5 }]);
});

// ── Apply ──

/** Overworld with region, entities and poi holding the same four chunks. */
function threeFolders(s, minutes) {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  for (const folder of ["region", "entities", "poi"]) {
    fx.writeRegion(
      s.regionFile(null, folder, 0, 0),
      0,
      0,
      minutes.map((m, i) => chunk(i, 0, m)),
    );
  }
}

const LEAN = { thresholdMinutes: 5, bufferChunks: 0, spawnRadiusChunks: 0, playerRadiusChunks: 0 };
const slotsIn = (s, folder) => region.occupiedSlots(region.readHeader(fs.readFileSync(s.regionFile(null, folder, 0, 0))));

test(
  "applying a plan removes the same chunks from region, entities and poi",
  withServer((s) => {
    threeFolders(s, [0, 60, 0, 60]);
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    const res = plan.applyPlan({ serverPath: s.dir, plan: p });
    assert.equal(res.deletedChunks, 2);
    assert.ok(res.bytesFreed > 0);
    for (const folder of ["region", "entities", "poi"]) assert.deepEqual(slotsIn(s, folder), [1, 3], folder);
    const again = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    assert.equal(again.plan.totals.delete, 0, "nothing is left to prune");
  }),
);

test(
  "a region left with no chunks loses its files, and external chunk files go with their chunk",
  withServer((s) => {
    threeFolders(s, [0, 0]);
    const ext = path.join(s.worldDir, "region", "c.1.0.mcc");
    fs.writeFileSync(ext, "x");
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    const res = plan.applyPlan({ serverPath: s.dir, plan: p });
    assert.equal(res.removedFiles, 3);
    for (const folder of ["region", "entities", "poi"]) assert.equal(fs.existsSync(s.regionFile(null, folder, 0, 0)), false);
    assert.equal(fs.existsSync(ext), false);
  }),
);

test(
  "a chunk that became busy since the preview is spared",
  withServer((s) => {
    threeFolders(s, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    // A player spends time in chunk 4 before the server stops.
    fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((i) => chunk(i, 0, i === 4 ? 90 : 0)));
    const res = plan.applyPlan({ serverPath: s.dir, plan: p });
    assert.equal(res.deletedChunks, 9);
    assert.deepEqual(slotsIn(s, "region"), [4]);
  }),
);

test(
  "a plan that no longer holds is refused and nothing is deleted",
  withServer((s) => {
    threeFolders(s, [0, 0, 0, 0]);
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [0, 1, 2, 3].map((i) => chunk(i, 0, 90)));
    assert.throws(() => plan.applyPlan({ serverPath: s.dir, plan: p }), (e) => e.code === "plan_stale");
    assert.deepEqual(slotsIn(s, "region"), [0, 1, 2, 3]);
  }),
);

test(
  "the folder a plan names is ignored: the fresh scan decides where to delete",
  withServer((s) => {
    threeFolders(s, [0, 0]);
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    p.dimensions[0].dir = "../../elsewhere";
    const res = plan.applyPlan({ serverPath: s.dir, plan: p });
    assert.equal(res.deletedChunks, 2);
  }),
);

test(
  "a plan whose deletions were edited is refused",
  withServer((s) => {
    threeFolders(s, [0, 0, 90]);
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    const dim = p.dimensions[0];
    const key = Object.keys(dim.deletions)[0];
    dim.deletions[key] = Buffer.alloc(128, 0xff).toString("base64");
    assert.throws(() => plan.applyPlan({ serverPath: s.dir, plan: p }), (e) => e.code === "plan_invalid");
    assert.deepEqual(slotsIn(s, "region"), [0, 1, 2]);
  }),
);

test(
  "an empty plan does nothing",
  withServer((s) => {
    threeFolders(s, [90, 90]);
    const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
    assert.deepEqual(plan.applyPlan({ serverPath: s.dir, plan: p }), { deletedChunks: 0, removedFiles: 0, bytesFreed: 0, planned: 0, skippedFiles: 0 });
  }),
);

// ── Safety edge cases ──

test("a chunk that was already corrupt stays and does not fail validation", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [
    chunk(0, 0, 0),
    { ...chunk(1, 0, 0), compression: "corrupt" },
    chunk(2, 0, 90),
  ]);
  const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  const res = plan.applyPlan({ serverPath: s.dir, plan: p });
  assert.equal(res.deletedChunks, 1);
  assert.deepEqual(slotsIn(s, "region"), [1, 2]);
}));

test("a region whose header overlaps two chunks is left alone", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  const file = s.regionFile(null, "region", 0, 0);
  fx.writeRegion(file, 0, 0, [chunk(0, 0, 0), chunk(1, 0, 90), chunk(2, 0, 90)]);
  const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  const buf = fs.readFileSync(file);
  buf.writeUInt32BE(buf.readUInt32BE(4), 8); // slot 2 now points at slot 1's sectors
  fs.writeFileSync(file, buf);
  const res = plan.applyPlan({ serverPath: s.dir, plan: p });
  assert.equal(res.deletedChunks, 0);
  assert.equal(res.skippedFiles, 1);
  assert.deepEqual(fs.readFileSync(file), buf);
}));

test("a chunk entry with no sectors reads as corrupt and makes the file unsafe", withServer((s) => {
  const file = s.regionFile(null, "region", 0, 0);
  fx.writeRegion(file, 0, 0, [chunk(0, 0, 0), chunk(1, 0, 0)]);
  const buf = fs.readFileSync(file);
  buf.writeUInt32BE((2 << 8) | 0, 4);
  const header = region.readHeader(buf);
  assert.equal(region.readChunk(buf, header, 1, path.dirname(file), 0, 0).reason, "corrupt");
  assert.deepEqual([...region.unsafeSlots(header)], [1]);
}));

test("a negative NBT array length is an error, not a loop", () => {
  const doc = (type) => Buffer.from([10, 0, 0, type, 0, 1, 0x61, 0xff, 0xff, 0xff, 0xff, 0]);
  for (const type of [7, 11, 12]) assert.throws(() => chunkMeta(doc(type)), /ended early/);
});

// ── Record cache ──

const withCache = (fn) =>
  withServer((s) => {
    const cacheDir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "mcsetup-prunecache-"));
    try {
      fn(s, cacheDir);
    } finally {
      fs.rmSync(cacheDir, { recursive: true, force: true });
    }
  });

function scanCounts(s, cacheDir, params = LEAN) {
  const profile = plan.newProfile();
  const r = plan.scanWorld({ serverPath: s.dir, params, profile, cacheDir });
  return { r, hits: profile.counts.cacheHits, misses: profile.counts.cacheMisses, chunks: profile.counts.chunks };
}

test("a second scan reads nothing and decides the same", withCache((s, cacheDir) => {
  threeFolders(s, [0, 60, 0, 60]);
  const first = scanCounts(s, cacheDir);
  assert.deepEqual([first.hits, first.misses, first.chunks], [0, 1, 4]);
  const second = scanCounts(s, cacheDir);
  assert.deepEqual([second.hits, second.misses, second.chunks], [1, 0, 0]);
  assert.equal(second.r.plan.hash, first.r.plan.hash);
}));

test("a changed parameter is a recompute over the cache, not a rescan", withCache((s, cacheDir) => {
  threeFolders(s, [0, 60, 0, 60]);
  scanCounts(s, cacheDir);
  const stricter = scanCounts(s, cacheDir, { ...LEAN, thresholdMinutes: 100 });
  assert.equal(stricter.chunks, 0);
  assert.equal(stricter.r.plan.totals.delete, 4);
  const uncached = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, thresholdMinutes: 100 } });
  assert.equal(stricter.r.plan.hash, uncached.plan.hash);
}));

test("a rewritten region file is read again", withCache((s, cacheDir) => {
  threeFolders(s, [0, 0, 0, 0]);
  assert.equal(scanCounts(s, cacheDir).r.plan.totals.delete, 4);
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [0, 1, 2, 3].map((i) => chunk(i, 0, i === 1 ? 90 : 0)));
  const again = scanCounts(s, cacheDir);
  assert.equal(again.misses, 1);
  assert.equal(again.r.plan.totals.delete, 3);
}));

test("a damaged or foreign cache entry is a miss", withCache((s, cacheDir) => {
  threeFolders(s, [0, 0]);
  scanCounts(s, cacheDir);
  const entry = path.join(cacheDir, "overworld", "r.0.0.meta");
  fs.writeFileSync(entry, Buffer.from("garbage"));
  const again = scanCounts(s, cacheDir);
  assert.equal(again.misses, 1);
  assert.equal(again.r.plan.totals.delete, 2);
  const bumped = fs.readFileSync(entry);
  bumped.writeUInt32BE(999, 4);
  fs.writeFileSync(entry, bumped);
  assert.equal(scanCounts(s, cacheDir).misses, 1);
}));

test("apply reads the regions it touches fresh, even when the cache says otherwise", withCache((s, cacheDir) => {
  threeFolders(s, [0, 0, 0, 0]);
  const { r } = scanCounts(s, cacheDir);
  // Poison the cached record: it claims every chunk is idle, the file says chunk 1 is busy
  // and keeps the same size and mtime would not be enough to fool the fingerprint, so
  // rewrite the file and put the old mtime back.
  const file = s.regionFile(null, "region", 0, 0);
  const before = fs.statSync(file);
  fx.writeRegion(file, 0, 0, [0, 1, 2, 3].map((i) => chunk(i, 0, i === 1 ? 90 : 0)));
  fs.utimesSync(file, before.atimeMs / 1000, before.mtimeMs / 1000);
  const res = plan.applyPlan({ serverPath: s.dir, plan: r.plan, cacheDir, tolerance: 0.5 });
  assert.equal(res.deletedChunks, 3);
  assert.deepEqual(slotsIn(s, "region"), [1]);
}));

test("the cache forgets regions that no longer exist", withCache((s, cacheDir) => {
  threeFolders(s, [0, 0]);
  scanCounts(s, cacheDir);
  fs.rmSync(s.regionFile(null, "region", 0, 0));
  fx.writeRegion(s.regionFile(null, "region", 1, 0), 1, 0, [chunk(32, 0, 0)]);
  scanCounts(s, cacheDir);
  assert.deepEqual(fs.readdirSync(path.join(cacheDir, "overworld")), ["r.1.0.meta"]);
}));

// ── Buffer ──

test("regions a million chunks apart no longer fail the scan", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 0, 0);
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [chunk(0, 0, 0), chunk(1, 0, 90)]);
  fx.writeRegion(s.regionFile(null, "region", 40000, -40000), 40000, -40000, [chunk(40000 * 32, -40000 * 32, 0)]);
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, bufferChunks: 2 } });
  assert.equal(r.plan.totals.chunks, 3);
}));

test("the buffer matches a brute-force Chebyshev distance across region borders", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 0, 0);
  let seed = 7;
  const rand = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const busy = new Map();
  for (const [rx, rz] of [[-1, -1], [0, -1], [-1, 0], [0, 0]]) {
    const list = [];
    for (let i = 0; i < 1024; i++) {
      const x = rx * 32 + (i & 31);
      const z = rz * 32 + (i >> 5);
      const isBusy = rand() < 0.02;
      busy.set(`${x},${z}`, isBusy);
      list.push(chunk(x, z, isBusy ? 90 : 0));
    }
    fx.writeRegion(s.regionFile(null, "region", rx, rz), rx, rz, list);
  }
  for (const n of [1, 3, 32]) {
    const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, bufferChunks: n } });
    let expected = 0;
    for (const [key, isBusy] of busy) {
      if (isBusy) continue;
      const [x, z] = key.split(",").map(Number);
      let near = false;
      for (let dz = -n; dz <= n && !near; dz++) {
        for (let dx = -n; dx <= n; dx++) {
          if (busy.get(`${x + dx},${z + dz}`)) {
            near = true;
            break;
          }
        }
      }
      if (!near) expected++;
    }
    assert.equal(r.plan.totals.delete, expected, `buffer ${n}`);
  }
}));
