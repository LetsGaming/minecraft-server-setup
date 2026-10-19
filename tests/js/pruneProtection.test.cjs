// What the prune keeps: forced chunks, respawn points, ids that match across files,
// parameters that are whole numbers, and the limits on what it reads.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");

const nbt = require("../../src/scripts/world/lib/nbt.js");
const region = require("../../src/scripts/world/lib/region.js");
const world = require("../../src/scripts/world/lib/world.js");
const plan = require("../../src/scripts/world/lib/plan.js");
const fx = require("./worldFixtures.cjs");

const MIN = plan.TICKS_PER_MINUTE;
const LEAN = { thresholdMinutes: 5, bufferChunks: 0, spawnRadiusChunks: 0, playerRadiusChunks: 0 };

function withServer(fn) {
  return () => {
    const server = fx.makeServer();
    try {
      fn(server);
    } finally {
      server.cleanup();
    }
  };
}

const chunk = (x, z, minutes) => ({ x, z, nbt: fx.chunkModern({ x, z, inhabited: minutes * MIN }) });

/** Four unused chunks in a row at z = 0 in the overworld, and a readable level.dat far away. */
function row(s, dimDir = null) {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  fx.writeRegion(s.regionFile(dimDir, "region", 0, 0), 0, 0, [0, 1, 2, 3].map((x) => chunk(x, 0, 0)));
}

const cellsOf = (r, id = "overworld", key = "r.0.0") => [...Buffer.from(r.maps[id].regions[key].cell, "base64").subarray(0, 4)];
const { CELL } = plan;

// ── forced chunks ──

test("a chunk kept loaded with /forceload is not deleted", withServer((s) => {
  row(s);
  fx.writeForcedChunks(s.worldDir, [[1, 0]]);
  const r = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  assert.deepEqual(cellsOf(r), [CELL.DELETE, CELL.PROTECTED, CELL.DELETE, CELL.DELETE]);
  assert.equal(r.plan.totals.delete, 3);
  assert.deepEqual(r.plan.warnings, []);
}));

test("forced chunks with negative coordinates unpack to the right chunk", withServer((s) => {
  fx.writeForcedChunks(s.worldDir, [[-3, -7], [5, 9]]);
  assert.deepEqual(world.readForcedChunks(s.worldDir), [{ x: -3, z: -7 }, { x: 5, z: 9 }]);
}));

test("forced chunks written as ticket entries are read too", withServer((s) => {
  row(s);
  fx.writeForcedChunks(s.worldDir, [[2, 0]], { format: "tickets" });
  const r = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  assert.deepEqual(cellsOf(r), [CELL.DELETE, CELL.DELETE, CELL.PROTECTED, CELL.DELETE]);
}));

test("forced chunks are read per dimension", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  const nether = path.join(s.worldDir, "DIM-1");
  fx.writeRegion(s.regionFile(nether, "region", 0, 0), 0, 0, [chunk(0, 0, 0), chunk(1, 0, 0)]);
  fx.writeForcedChunks(nether, [[0, 0]]);
  const r = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  const cell = [...Buffer.from(r.maps.the_nether.regions["r.0.0"].cell, "base64").subarray(0, 2)];
  assert.deepEqual(cell, [CELL.PROTECTED, CELL.DELETE]);
}));

test("a chunks.dat that cannot be read is reported, because its chunks are then unprotected", withServer((s) => {
  row(s);
  fx.writeForcedChunks(s.worldDir, [], { format: "corrupt" });
  const r = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  assert.ok(r.plan.warnings.includes("forced_chunks_unreadable"));
}));

// ── respawn points and unreadable players ──

test("a respawn point protects the area around it like a player's position", withServer((s) => {
  row(s);
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  fx.writePlayer(s.worldDir, "aaaa", { x: 90_000, z: 90_000, spawn: { x: 16, z: 0 } });
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, playerRadiusChunks: 0 } });
  assert.deepEqual(cellsOf(r), [CELL.DELETE, CELL.DELETE, CELL.DELETE, CELL.DELETE], "no radius, no protection");
  const kept = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, playerRadiusChunks: 1 } });
  assert.deepEqual(cellsOf(kept), [CELL.PROTECTED, CELL.PROTECTED, CELL.PROTECTED, CELL.DELETE], "chunk 1 +- 1");
}));

test("the respawn compound of 1.21.5 and later is read", withServer((s) => {
  row(s);
  fx.writePlayer(s.worldDir, "bbbb", { x: 90_000, z: 90_000, respawn: { x: 48, z: 0 } });
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, playerRadiusChunks: 0 } });
  assert.deepEqual(cellsOf(r), [CELL.DELETE, CELL.DELETE, CELL.DELETE, CELL.DELETE]);
  const players = world.readPlayerPositions(s.worldDir);
  assert.deepEqual(
    players.map((p) => [p.kind, p.dimension, p.x, p.z]),
    [["player", "overworld", 90_000, 90_000], ["respawn", "overworld", 48, 0]],
  );
}));

test("a respawn point in another dimension protects that dimension", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  const nether = path.join(s.worldDir, "DIM-1");
  fx.writeRegion(s.regionFile(nether, "region", 0, 0), 0, 0, [chunk(0, 0, 0), chunk(1, 0, 0)]);
  fx.writePlayer(s.worldDir, "cccc", { x: 90_000, z: 90_000, spawn: { x: 16, z: 0, dimension: "minecraft:the_nether" } });
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, playerRadiusChunks: 0 } });
  const cell = [...Buffer.from(r.maps.the_nether.regions["r.0.0"].cell, "base64").subarray(0, 2)];
  assert.deepEqual(cell, [CELL.DELETE, CELL.DELETE]);
  const withRadius = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, playerRadiusChunks: 1 } });
  const protectedCells = [...Buffer.from(withRadius.maps.the_nether.regions["r.0.0"].cell, "base64").subarray(0, 2)];
  assert.deepEqual(protectedCells, [CELL.PROTECTED, CELL.PROTECTED]);
}));

test("an unreadable player file is a warning, not a silent skip", withServer((s) => {
  row(s);
  fx.writePlayer(s.worldDir, "dddd", { x: 0, z: 0, corrupt: true });
  const issues = {};
  assert.deepEqual(world.readPlayerPositions(s.worldDir, issues), []);
  assert.deepEqual(issues.unreadablePlayers, ["dddd.dat"]);
  const r = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  assert.ok(r.plan.warnings.includes("player_files_unreadable"));
}));

// ── dimension ids ──

test("a dimension id is the same whichever file it comes from", withServer((s) => {
  assert.equal(world.normalizeDimensionId("minecraft:custom"), "custom");
  assert.equal(world.dimensionIdOf("minecraft:custom"), "custom");
  assert.equal(world.dimensionIdOf("mod:deep"), "mod:deep");
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  const custom = path.join(s.worldDir, "dimensions", "minecraft", "custom");
  fx.writeRegion(s.regionFile(custom, "region", 0, 0), 0, 0, [chunk(0, 0, 0), chunk(1, 0, 0)]);
  assert.deepEqual(world.discoverDimensions(s.worldDir).map((d) => d.id), ["custom"]);
  fx.writePlayer(s.worldDir, "eeee", { x: 0, z: 0, dimension: "minecraft:custom" });
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, playerRadiusChunks: 1 } });
  assert.equal(r.plan.dimensions[0].delete, 0, "the player in minecraft:custom protects the custom dimension");
}));

test("zones, selections and dimension filters accept the namespaced spelling", () => {
  const p = plan.normalizeParams({
    dimensions: ["minecraft:overworld"],
    zones: [{ dimension: "minecraft:the_nether", x1: 0, z1: 0, x2: 1, z2: 1 }],
    selection: { ops: [{ dimension: "minecraft:overworld", mode: "add", x1: 0, z1: 0, x2: 1, z2: 1 }] },
  });
  assert.deepEqual(p.dimensions, ["overworld"]);
  assert.equal(p.zones[0].dimension, "the_nether");
  assert.equal(p.selection.ops[0].dimension, "overworld");
});

// ── whole-number parameters ──

test("fractional buffer, radii and threshold are rounded to whole numbers", () => {
  const p = plan.normalizeParams({ bufferChunks: 1.5, spawnRadiusChunks: 3.4, playerRadiusChunks: 2.6, thresholdMinutes: 4.5 });
  assert.equal(p.bufferChunks, 2);
  assert.equal(p.spawnRadiusChunks, 3);
  assert.equal(p.playerRadiusChunks, 3);
  assert.equal(p.thresholdMinutes, 5);
});

test("a fractional buffer still protects the neighbours of a busy chunk", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [chunk(0, 0, 60), chunk(1, 0, 0), chunk(2, 0, 0), chunk(3, 0, 0)]);
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, bufferChunks: 1.5 } });
  assert.equal(r.plan.params.bufferChunks, 2);
  assert.deepEqual(cellsOf(r), [CELL.ACTIVE, CELL.BUFFER, CELL.BUFFER, CELL.DELETE]);
}));

// ── a huge selection ──

test("a selection rectangle across the whole coordinate range is cheap", withServer((s) => {
  row(s);
  const started = Date.now();
  const op = { dimension: "overworld", mode: "add", x1: -30_000_000, z1: -30_000_000, x2: 30_000_000, z2: 30_000_000 };
  const r = plan.scanWorld({ serverPath: s.dir, params: { ...LEAN, selection: { ops: [op], allowProtected: false } } });
  assert.ok(Date.now() - started < 5000, "finished in seconds, not by walking billions of regions");
  assert.equal(r.plan.totals.delete, 4);
}));

// ── limits on what is read ──

test("a chunk that inflates past the cap is unreadable and left alone", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  const bomb = Buffer.alloc(region.MAX_CHUNK_BYTES + 1024 * 1024);
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [{ x: 0, z: 0, nbt: bomb }, chunk(1, 0, 0)]);
  const buf = fs.readFileSync(s.regionFile(null, "region", 0, 0));
  const header = region.readHeader(buf);
  assert.deepEqual(region.readChunk(buf, header, 0, null, 0, 0), { ok: false, reason: "corrupt" });
  assert.equal(region.readChunk(buf, header, 1, null, 0, 0).ok, true);
  const r = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  assert.equal(r.plan.dimensions[0].unreadable, 1);
  assert.equal(r.plan.dimensions[0].delete, 1);
}));

test("an external chunk file above the cap is not read", withServer((s) => {
  fx.writeLevelDat(s.worldDir, 100_000, 100_000);
  const file = s.regionFile(null, "region", 0, 0);
  fx.writeRegion(file, 0, 0, [chunk(0, 0, 0)]);
  const buf = fs.readFileSync(file);
  const header = region.readHeader(buf);
  const start = region.sectorOffset(header.locations[0]) * region.SECTOR;
  buf[start + 4] |= 128; // the chunk now lives in c.0.0.mcc
  const dir = path.dirname(file);
  const big = path.join(dir, region.externalName(0, 0));
  fs.writeFileSync(big, Buffer.alloc(region.MAX_CHUNK_BYTES + 1));
  assert.deepEqual(region.readChunk(buf, header, 0, dir, 0, 0), { ok: false, reason: "corrupt" });
}));

// ── the search must not be fooled by a tag inside item data ──

const u16 = (n) => Buffer.from([n >> 8, n & 255]);
const i32 = (n) => {
  const b = Buffer.alloc(4);
  b.writeInt32BE(n);
  return b;
};
const i64 = (n) => {
  const b = Buffer.alloc(8);
  b.writeBigInt64BE(BigInt(n));
  return b;
};
const named = (type, name, payload) => Buffer.concat([Buffer.from([type]), u16(name.length), Buffer.from(name), payload]);

test("an InhabitedTime planted inside a block entity does not stand in for the real one", () => {
  const spoof = named(4, "InhabitedTime", i64(999_999_999));
  const chest = Buffer.concat([named(8, "id", Buffer.concat([u16(15), Buffer.from("minecraft:chest")])), spoof, Buffer.from([0])]);
  const blockEntities = named(9, "block_entities", Buffer.concat([Buffer.from([10]), i32(1), chest]));
  // Block entities first, the real value after them: hash order allows either.
  const doc = Buffer.concat([Buffer.from([10, 0, 0]), blockEntities, named(4, "InhabitedTime", i64(5)), Buffer.from([0])]);
  assert.equal(nbt.chunkSignals(doc).inhabited, 5);
  assert.equal(nbt.chunkSignalsFast(doc).inhabited, 5);
  assert.deepEqual(nbt.chunkSignalsFast(doc), nbt.chunkSignals(doc));
});

test("a spoofed InhabitedTime with no real one leaves the chunk unreadable", () => {
  const spoof = named(4, "InhabitedTime", i64(999_999_999));
  const chest = Buffer.concat([spoof, Buffer.from([0])]);
  const blockEntities = named(9, "block_entities", Buffer.concat([Buffer.from([10]), i32(1), chest]));
  const doc = Buffer.concat([Buffer.from([10, 0, 0]), blockEntities, Buffer.from([0])]);
  assert.equal(nbt.chunkSignalsFast(doc).inhabited, undefined);
});

test("the search still reads the legacy Level layout", () => {
  const legacy = fx.chunkLegacy({ x: 1, z: 2, inhabited: 4242 });
  assert.equal(nbt.chunkSignalsFast(legacy).inhabited, 4242);
});

// ── applying with an unknown spawn ──

test("a plan made without a readable level.dat is refused unless the override is given", withServer((s) => {
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [chunk(0, 0, 0), chunk(1, 0, 0)]);
  const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  assert.ok(p.warnings.includes("spawn_unknown"));
  assert.throws(() => plan.applyPlan({ serverPath: s.dir, plan: p }), (e) => e.code === "spawn_unknown");
  assert.equal(region.occupiedSlots(region.readHeader(fs.readFileSync(s.regionFile(null, "region", 0, 0)))).length, 2, "nothing deleted");
  const res = plan.applyPlan({ serverPath: s.dir, plan: p, allowUnknownSpawn: true });
  assert.equal(res.deletedChunks, 2);
}));

test("a level.dat that became unreadable after the scan also stops the apply", withServer((s) => {
  row(s);
  const { plan: p } = plan.scanWorld({ serverPath: s.dir, params: LEAN });
  fs.writeFileSync(path.join(s.worldDir, "level.dat"), zlib.gzipSync(Buffer.from("junk")));
  assert.throws(() => plan.applyPlan({ serverPath: s.dir, plan: p }), (e) => e.code === "spawn_unknown");
}));
