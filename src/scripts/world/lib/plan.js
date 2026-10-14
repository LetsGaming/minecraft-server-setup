"use strict";

/**
 * Chunk pruning: decide which generated chunks nobody has used, and carry the
 * decision out.
 *
 * "Unused" is InhabitedTime, the ticks a player spent near a chunk, below a
 * threshold. Never pruned, whatever the threshold says: chunks around the
 * world spawn, around where each player last was, inside zones the admin drew,
 * chunks this cannot read, and a buffer of N chunks around everything that
 * stays (so a build does not end at a fresh-terrain seam).
 *
 * scan() only reads. apply() deletes exactly what a plan names, after scanning
 * again, so an old preview can only ever remove less than it promised.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const cache = require("./cache");
const scan = require("./scan");
const region = require("./region");
const world = require("./world");
const { SIGNAL, chunkSignals, parseNbt } = require("./nbt");

const TICKS_PER_MINUTE = 20 * 60;

/** What each chunk cell is, for the map and for the decision. */
const CELL = {
  EMPTY: 0,
  DELETE: 1,
  ACTIVE: 2,
  PROTECTED: 3,
  BUFFER: 4,
  UNREADABLE: 5,
  /** Chosen by hand, overriding a soft rule (in use, buffer). */
  MANUAL_SOFT: 6,
  /** Chosen by hand, overriding a hard protection (needs `selection.allowProtected`). */
  MANUAL_HARD: 7,
  /** Would be deleted by the rules, but holds things players usually put there (see isUnexplained). */
  UNCERTAIN: 8,
};

/**
 * Block entities (chests, signs, furnaces, beds, redstone parts, anything modded) in a
 * chunk that has neither a generated structure nor a spawner to account for them.
 * Villages, mineshafts and ruins hold plenty of these by themselves, and a dungeon is
 * a spawner and a chest, so those do not count. What is left is mostly built by hand.
 * Advisory: it can be wrong both ways, which is why it only keeps a chunk, never deletes.
 */
function isUnexplained(flags) {
  const placed = SIGNAL.CONTAINER | SIGNAL.SIGN | SIGNAL.FURNACE | SIGNAL.BED | SIGNAL.REDSTONE | SIGNAL.OTHER_BLOCK_ENTITY;
  const natural = SIGNAL.STRUCTURE_START | SIGNAL.STRUCTURE_REFERENCE | SIGNAL.SPAWNER;
  return (flags & placed) !== 0 && (flags & natural) === 0;
}

/** Cells that go: what the rules found and what was chosen by hand. */
const isDeletion = (c) => c === CELL.DELETE || c === CELL.MANUAL_SOFT || c === CELL.MANUAL_HARD;

/** Operations in a manual selection; past this the parameters would not fit on a command line. */
const MAX_SELECTION_OPS = 2500;
const MAX_COORD = 2_000_000;

const DEFAULT_PARAMS = Object.freeze({
  thresholdMinutes: 5,
  spawnRadiusChunks: 16,
  playerRadiusChunks: 8,
  bufferChunks: 2,
  zones: [],
  dimensions: null,
  selection: Object.freeze({ ops: [], allowProtected: false }),
  buildProtection: "likely",
});

/** "off" ignores what a chunk contains; "likely" keeps chunks with block entities no structure explains. */
const BUILD_PROTECTION = ["off", "likely"];

/**
 * A manual selection as an ordered list of rectangles in chunk coordinates:
 * "add" puts chunks in, "remove" takes them out again, later operations win.
 * Never-deletable chunks (unreadable ones) and, unless `allowProtected`, hard
 * protections (spawn, players, drawn zones) stay whatever the selection says.
 */
function normalizeSelection(input) {
  const out = { ops: [], allowProtected: false };
  if (!input || typeof input !== "object") return out;
  out.allowProtected = input.allowProtected === true;
  if (!Array.isArray(input.ops)) return out;
  for (const op of input.ops) {
    if (out.ops.length >= MAX_SELECTION_OPS) break;
    if (!op || typeof op.dimension !== "string" || (op.mode !== "add" && op.mode !== "remove")) continue;
    const c = [op.x1, op.z1, op.x2, op.z2].map((v) => Math.trunc(v));
    if (!c.every((v) => Number.isFinite(v) && Math.abs(v) <= MAX_COORD)) continue;
    out.ops.push({
      dimension: op.dimension,
      mode: op.mode,
      x1: Math.min(c[0], c[2]),
      z1: Math.min(c[1], c[3]),
      x2: Math.max(c[0], c[2]),
      z2: Math.max(c[1], c[3]),
    });
  }
  return out;
}

function normalizeParams(input = {}) {
  const num = (v, d, min, max) => {
    const n = typeof v === "number" && Number.isFinite(v) ? v : d;
    return Math.min(max, Math.max(min, n));
  };
  const zones = Array.isArray(input.zones)
    ? input.zones
        .filter((z) => z && typeof z.dimension === "string")
        .map((z) => ({
          name: typeof z.name === "string" ? z.name.slice(0, 64) : "",
          dimension: z.dimension,
          x1: Math.min(Math.trunc(z.x1), Math.trunc(z.x2)),
          z1: Math.min(Math.trunc(z.z1), Math.trunc(z.z2)),
          x2: Math.max(Math.trunc(z.x1), Math.trunc(z.x2)),
          z2: Math.max(Math.trunc(z.z1), Math.trunc(z.z2)),
        }))
        .filter((z) => [z.x1, z.z1, z.x2, z.z2].every(Number.isFinite))
    : [];
  return {
    thresholdMinutes: num(input.thresholdMinutes, DEFAULT_PARAMS.thresholdMinutes, 0, 100_000),
    spawnRadiusChunks: num(input.spawnRadiusChunks, DEFAULT_PARAMS.spawnRadiusChunks, 0, 512),
    playerRadiusChunks: num(input.playerRadiusChunks, DEFAULT_PARAMS.playerRadiusChunks, 0, 512),
    bufferChunks: num(input.bufferChunks, DEFAULT_PARAMS.bufferChunks, 0, 32),
    zones,
    dimensions: Array.isArray(input.dimensions) ? input.dimensions.filter((d) => typeof d === "string") : null,
    selection: normalizeSelection(input.selection),
    buildProtection: BUILD_PROTECTION.includes(input.buildProtection) ? input.buildProtection : DEFAULT_PARAMS.buildProtection,
  };
}

const blockToChunk = (b) => Math.floor(b / 16);

/** Chunk-coordinate rectangles that are protected in one dimension. */
function protectedRects(dimId, params, spawn, players) {
  const rects = [];
  if (dimId === world.DIMENSION_IDS.OVERWORLD && params.spawnRadiusChunks > 0) {
    const cx = blockToChunk(spawn?.x ?? 0);
    const cz = blockToChunk(spawn?.z ?? 0);
    const r = params.spawnRadiusChunks;
    rects.push({ kind: "spawn", x1: cx - r, z1: cz - r, x2: cx + r, z2: cz + r });
  }
  if (params.playerRadiusChunks > 0) {
    for (const p of players) {
      if (p.dimension !== dimId) continue;
      const cx = blockToChunk(p.x);
      const cz = blockToChunk(p.z);
      const r = params.playerRadiusChunks;
      rects.push({ kind: "player", x1: cx - r, z1: cz - r, x2: cx + r, z2: cz + r });
    }
  }
  for (const z of params.zones) {
    if (z.dimension === dimId) rects.push({ kind: "zone", name: z.name, x1: z.x1, z1: z.z1, x2: z.x2, z2: z.z2 });
  }
  return rects;
}

/** The pieces of a dimension's region/ folder, in a stable order. */
function listRegions(dimDir) {
  const dir = path.join(dimDir, "region");
  const out = [];
  for (const name of fs.readdirSync(dir).sort()) {
    const parsed = region.parseRegionName(name);
    if (parsed) out.push({ ...parsed, name, file: path.join(dir, name) });
  }
  return out;
}

/**
 * Phase timer for --profile. Without a profile object every call is a plain
 * pass-through, so the scan pays nothing when nobody asked.
 */
function timed(profile, name, fn) {
  if (!profile) return fn();
  const t0 = process.hrtime.bigint();
  try {
    return fn();
  } finally {
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    profile.phases[name] = (profile.phases[name] ?? 0) + ms;
  }
}

/** Log-ish 0..255 level of an InhabitedTime in minutes, for the heat map. */
function heatLevel(minutes) {
  if (!(minutes > 0)) return 0;
  return Math.min(255, Math.round((Math.log10(1 + minutes) / 4) * 255));
}

/**
 * Read one dimension and classify every chunk. Returns the grid of cells with
 * enough per-chunk data to build the plan and the map.
 */
function scanDimension({ dimId, dimDir, params, spawn, players, onRegion, profile, cacheDir, fresh }) {
  const signals = params.buildProtection !== "off";
  const thresholdTicks = params.thresholdMinutes * TICKS_PER_MINUTE;
  const regions = listRegions(dimDir);
  const cells = new Map(); // "rx,rz" -> {cell:Uint8Array(1024), heat:Uint8Array(1024), bytes:Uint32Array(1024)}

  const live = new Set();
  for (const r of regions) {
    const key = `${dimId}:${r.x},${r.z}`;
    let record = null;
    let fp = null;
    if (cacheDir && !fresh.has(key)) {
      fp = timed(profile, "fingerprint", () => cache.fingerprint(r.file));
      record = timed(profile, "cacheLoad", () => cache.load(cacheDir, dimId, r.x, r.z, fp, signals));
      if (profile) profile.counts[record ? "cacheHits" : "cacheMisses"]++;
    }
    if (!record) {
      record = scan.readRegionRecord(
        r.file,
        r.x,
        r.z,
        (name, fn) => timed(profile, name, fn),
        profile ? () => profile.counts.chunks++ : undefined,
        { signals },
      );
      if (cacheDir && record) {
        fp = fp ?? cache.fingerprint(r.file);
        cache.store(cacheDir, dimId, r.x, r.z, fp, record);
      }
    }
    if (!record) continue;
    live.add(`${r.x},${r.z}`);

    const cell = new Uint8Array(region.CHUNKS);
    const heat = new Uint8Array(region.CHUNKS);
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      const st = record.state[slot];
      if (st === scan.STATE.EMPTY) continue;
      if (st === scan.STATE.UNREADABLE) {
        cell[slot] = CELL.UNREADABLE;
        continue;
      }
      heat[slot] = heatLevel(record.ticks[slot] / TICKS_PER_MINUTE);
      if (record.ticks[slot] >= thresholdTicks) cell[slot] = CELL.ACTIVE;
      else if (signals && isUnexplained(record.flags[slot])) cell[slot] = CELL.UNCERTAIN;
      else cell[slot] = CELL.DELETE;
    }

    cells.set(`${r.x},${r.z}`, { rx: r.x, rz: r.z, cell, heat, bytes: record.bytes, file: r.file });
    if (profile) profile.counts.regions++;
    if (onRegion) onRegion();
  }
  if (cacheDir) cache.prune(cacheDir, dimId, live);

  if (cells.size === 0) return { cells, regions: 0, manual: { soft: 0, hard: 0, blocked: 0 } };

  // Protected zones first: they turn a would-be deletion into a keep.
  const rects = protectedRects(dimId, params, spawn, players);
  const tClassify = profile ? process.hrtime.bigint() : 0n;
  for (const entry of cells.values()) {
    for (const rect of rects) {
      const rx0 = entry.rx * 32;
      const rz0 = entry.rz * 32;
      if (rect.x2 < rx0 || rect.x1 > rx0 + 31 || rect.z2 < rz0 || rect.z1 > rz0 + 31) continue;
      for (let slot = 0; slot < region.CHUNKS; slot++) {
        if (entry.cell[slot] !== CELL.DELETE) continue;
        const cx = rx0 + region.slotX(slot);
        const cz = rz0 + region.slotZ(slot);
        if (cx >= rect.x1 && cx <= rect.x2 && cz >= rect.z1 && cz <= rect.z2) entry.cell[slot] = CELL.PROTECTED;
      }
    }
  }

  if (profile) profile.phases.classify = (profile.phases.classify ?? 0) + Number(process.hrtime.bigint() - tClassify) / 1e6;

  // Buffer: a deletion candidate within N chunks of anything that stays is kept.
  if (params.bufferChunks > 0) {
    timed(profile, "buffer", () => applyBuffer(cells, params.bufferChunks));
  }

  const manual = timed(profile, "selection", () => applySelection(dimId, cells, params.selection, rects));
  return { cells, regions: cells.size, manual };
}

const inRects = (rects, cx, cz) => rects.some((r) => cx >= r.x1 && cx <= r.x2 && cz >= r.z1 && cz <= r.z2);

/**
 * Turn the chunks chosen by hand into deletions where the rules allow it.
 * Returns how many were chosen over a soft rule, over a hard protection, and
 * how many could not be honoured (unreadable, or protected without the override).
 */
function applySelection(dimId, cells, selection, rects) {
  const result = { soft: 0, hard: 0, blocked: 0 };
  const ops = selection.ops.filter((o) => o.dimension === dimId);
  if (ops.length === 0) return result;

  const chosen = new Map(); // "rx,rz" -> Uint8Array(1024) of 0/1
  const bitsOf = (rx, rz) => {
    const key = `${rx},${rz}`;
    let bits = chosen.get(key);
    if (!bits) {
      bits = new Uint8Array(region.CHUNKS);
      chosen.set(key, bits);
    }
    return bits;
  };
  for (const op of ops) {
    const value = op.mode === "add" ? 1 : 0;
    // Only regions that exist matter; a rectangle over empty space chooses nothing.
    for (let rz = Math.floor(op.z1 / 32); rz <= Math.floor(op.z2 / 32); rz++) {
      for (let rx = Math.floor(op.x1 / 32); rx <= Math.floor(op.x2 / 32); rx++) {
        if (!cells.has(`${rx},${rz}`)) continue;
        const bits = bitsOf(rx, rz);
        const xa = Math.max(op.x1, rx * 32) - rx * 32;
        const xb = Math.min(op.x2, rx * 32 + 31) - rx * 32;
        const za = Math.max(op.z1, rz * 32) - rz * 32;
        const zb = Math.min(op.z2, rz * 32 + 31) - rz * 32;
        for (let z = za; z <= zb; z++) for (let x = xa; x <= xb; x++) bits[z * 32 + x] = value;
      }
    }
  }

  for (const [key, bits] of chosen) {
    const entry = cells.get(key);
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      if (!bits[slot]) continue;
      const c = entry.cell[slot];
      if (c === CELL.EMPTY || c === CELL.DELETE) continue;
      if (c === CELL.UNREADABLE) {
        result.blocked++;
        continue;
      }
      const hard = inRects(rects, entry.rx * 32 + region.slotX(slot), entry.rz * 32 + region.slotZ(slot));
      if (hard) {
        if (!selection.allowProtected) {
          result.blocked++;
          continue;
        }
        entry.cell[slot] = CELL.MANUAL_HARD;
        result.hard++;
      } else {
        entry.cell[slot] = CELL.MANUAL_SOFT;
        result.soft++;
      }
    }
  }
  return result;
}

const isKeep = (c) => c === CELL.ACTIVE || c === CELL.PROTECTED || c === CELL.UNREADABLE || c === CELL.UNCERTAIN;

/**
 * A deletion candidate within `n` chunks (Chebyshev distance) of anything that
 * stays becomes BUFFER. Each region is decided from a local grid of its own
 * chunks plus an `n` chunk halo taken from its neighbours (n is at most 32, so
 * only the eight adjacent regions can matter), so memory is bounded per region
 * and a far-away region cannot make the whole scan fail.
 */
function applyBuffer(cells, n) {
  const side = region.CHUNKS ** 0.5; // 32
  const w = side + 2 * n;
  const keep = new Uint8Array(w * w);
  const sum = new Int32Array((w + 1) * (w + 1));

  for (const entry of cells.values()) {
    let any = false;
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      if (entry.cell[slot] === CELL.DELETE) {
        any = true;
        break;
      }
    }
    if (!any) continue;

    keep.fill(0);
    for (let dz = -1; dz <= 1; dz++) {
      for (let dx = -1; dx <= 1; dx++) {
        const other = cells.get(`${entry.rx + dx},${entry.rz + dz}`);
        if (!other) continue;
        for (let slot = 0; slot < region.CHUNKS; slot++) {
          if (!isKeep(other.cell[slot])) continue;
          // Local coordinates: the region's own chunks start at (n, n).
          const x = dx * side + region.slotX(slot) + n;
          const z = dz * side + region.slotZ(slot) + n;
          if (x >= 0 && x < w && z >= 0 && z < w) keep[z * w + x] = 1;
        }
      }
    }
    // Summed-area table: a window count is four lookups.
    for (let z = 0; z < w; z++) {
      let row = 0;
      for (let x = 0; x < w; x++) {
        row += keep[z * w + x];
        sum[(z + 1) * (w + 1) + x + 1] = sum[z * (w + 1) + x + 1] + row;
      }
    }
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      if (entry.cell[slot] !== CELL.DELETE) continue;
      const x = region.slotX(slot) + n;
      const z = region.slotZ(slot) + n;
      const x0 = x - n;
      const z0 = z - n;
      const x1 = x + n + 1;
      const z1 = z + n + 1;
      const count = sum[z1 * (w + 1) + x1] - sum[z0 * (w + 1) + x1] - sum[z1 * (w + 1) + x0] + sum[z0 * (w + 1) + x0];
      if (count > 0) entry.cell[slot] = CELL.BUFFER;
    }
  }
}

const b64 = (typed) => Buffer.from(typed.buffer, typed.byteOffset, typed.byteLength).toString("base64");

function deletionBitmap(cell) {
  const bits = new Uint8Array(region.CHUNKS / 8);
  let count = 0;
  for (let slot = 0; slot < region.CHUNKS; slot++) {
    if (isDeletion(cell[slot])) {
      bits[slot >> 3] |= 1 << (slot & 7);
      count++;
    }
  }
  return { bits, count };
}

function slotsOfBitmap(base64) {
  const bits = Buffer.from(base64, "base64");
  const out = [];
  for (let slot = 0; slot < region.CHUNKS; slot++) if (bits[slot >> 3] & (1 << (slot & 7))) out.push(slot);
  return out;
}

/**
 * Read-only scan of a whole world.
 *
 * @returns {{plan: object, maps: Record<string, object>}} `plan` carries the
 *   deletions and totals; `maps` is one cell/heat map per dimension for the UI.
 */
function scanWorld({ serverPath, params: rawParams, onProgress, profile, cacheDir = null, fresh = new Set() }) {
  const params = normalizeParams(rawParams);
  const worldDir = world.worldDirOf(serverPath);
  const spawn = world.readSpawn(worldDir);
  const players = world.readPlayerPositions(worldDir);
  const warnings = [];
  if (!spawn) warnings.push("spawn_unknown");

  const dims = world
    .discoverDimensions(worldDir)
    .filter((d) => !params.dimensions || params.dimensions.includes(d.id));

  const plan = {
    version: 1,
    createdAt: new Date().toISOString(),
    params,
    warnings,
    dimensions: [],
    totals: { chunks: 0, delete: 0, regions: 0, regionsEmptied: 0, bytes: 0 },
  };
  const maps = {};

  for (const dim of dims) {
    const { cells, manual } = scanDimension({
      dimId: dim.id,
      dimDir: dim.dir,
      params,
      spawn,
      players,
      onRegion: onProgress,
      profile,
      cacheDir,
      fresh,
    });

    const counts = {
      chunks: 0,
      delete: 0,
      active: 0,
      protected: 0,
      buffer: 0,
      unreadable: 0,
      uncertain: 0,
      manualSoft: manual?.soft ?? 0,
      manualHard: manual?.hard ?? 0,
      manualBlocked: manual?.blocked ?? 0,
    };
    const deletions = {};
    const mapRegions = {};
    let bytes = 0;
    let regionsEmptied = 0;

    const tAssemble = profile ? process.hrtime.bigint() : 0n;
    for (const entry of [...cells.values()].sort((a, b) => a.rx - b.rx || a.rz - b.rz)) {
      const key = `r.${entry.rx}.${entry.rz}`;
      mapRegions[key] = { cell: b64(entry.cell), heat: b64(entry.heat) };
      const { bits, count } = deletionBitmap(entry.cell);
      // Sibling headers are read once per region file, and only when something goes.
      const siblings =
        count > 0
          ? timed(profile, "slotBytes", () =>
              ["entities", "poi"].map((folder) => scan.siblingSectorBytes(path.join(dim.dir, folder, region.regionName(entry.rx, entry.rz)))),
            )
          : null;
      let occupied = 0;
      for (let slot = 0; slot < region.CHUNKS; slot++) {
        const c = entry.cell[slot];
        if (c === CELL.EMPTY) continue;
        occupied++;
        if (c === CELL.ACTIVE) counts.active++;
        else if (c === CELL.PROTECTED) counts.protected++;
        else if (c === CELL.BUFFER) counts.buffer++;
        else if (c === CELL.UNREADABLE) counts.unreadable++;
        else if (c === CELL.UNCERTAIN) counts.uncertain++;
        if (isDeletion(c)) {
          bytes += entry.bytes[slot] + (siblings ? siblings[0][slot] + siblings[1][slot] : 0);
        }
      }
      counts.chunks += occupied;
      counts.delete += count;
      if (count > 0) {
        deletions[key] = b64(bits);
        if (count === occupied) regionsEmptied++;
      }
    }

    if (profile) profile.phases.assemble = (profile.phases.assemble ?? 0) + Number(process.hrtime.bigint() - tAssemble) / 1e6;
    plan.dimensions.push({
      id: dim.id,
      dir: path.relative(serverPath, dim.dir).split(path.sep).join("/"),
      regions: cells.size,
      ...counts,
      regionsEmptied,
      bytes,
      deletions,
    });
    maps[dim.id] = { regions: mapRegions };
    plan.totals.chunks += counts.chunks;
    plan.totals.delete += counts.delete;
    plan.totals.regions += cells.size;
    plan.totals.regionsEmptied += regionsEmptied;
    plan.totals.bytes += bytes;
  }

  plan.hash = planHash(plan);
  plan.id = plan.hash.slice(0, 16);
  return { plan, maps };
}

/**
 * Every region file a scan of these parameters would read, for warming the cache
 * in parallel before the (cheap, single-threaded) decision runs.
 */
function listScanJobs({ serverPath, params: rawParams }) {
  const params = normalizeParams(rawParams);
  const worldDir = world.worldDirOf(serverPath);
  const jobs = [];
  for (const dim of world.discoverDimensions(worldDir)) {
    if (params.dimensions && !params.dimensions.includes(dim.id)) continue;
    for (const r of listRegions(dim.dir)) jobs.push({ file: r.file, dimId: dim.id, rx: r.x, rz: r.z });
  }
  return jobs;
}

/** The dimensions of a world and how many region files each has. Reads directory listings only. */
function listDimensions({ serverPath }) {
  return world.discoverDimensions(world.worldDirOf(serverPath)).map((dim) => {
    let regions = 0;
    try {
      regions = listRegions(dim.dir).length;
    } catch {
      /* a dimension folder without region files */
    }
    return { id: dim.id, regions };
  });
}

const SIGNAL_NAMES = Object.entries(SIGNAL).map(([name, bit]) => [bit, name.toLowerCase()]);

/**
 * Everything the engine can tell about one chunk of a plan, read from the world
 * right now: what it contains, why a rule would keep or delete it, and how much
 * space it takes. The chunk is read and decoded in full (it is one chunk), so
 * this is the place for detail that would be too heavy to keep for every chunk.
 */
function inspectChunk({ serverPath, plan, dimension, cx, cz }) {
  const dim = plan.dimensions.find((d) => d.id === dimension);
  if (!dim) {
    const err = new Error("That plan has no such dimension.");
    err.code = "dimension";
    throw err;
  }
  const worldDir = world.worldDirOf(serverPath);
  const dimDir = path.join(serverPath, ...dim.dir.split("/").filter(Boolean));
  if (!isInside(worldDir, dimDir)) throw new Error("A plan names a folder outside the world.");

  const rx = Math.floor(cx / 32);
  const rz = Math.floor(cz / 32);
  const slot = region.slotOf(cx, cz);
  const file = path.join(dimDir, "region", region.regionName(rx, rz));
  const out = { chunk: { dimension, cx, cz, rx, rz, slot }, thresholdMinutes: plan.params.thresholdMinutes };

  let buf;
  try {
    buf = fs.readFileSync(file);
  } catch {
    return { ...out, present: false };
  }
  const header = region.readHeader(buf);
  if (!header || header.locations[slot] === 0) return { ...out, present: false };

  out.present = true;
  out.bytes = {
    region: region.sectorCount(header.locations[slot]) * region.SECTOR,
    entities: scan.siblingSectorBytes(path.join(dimDir, "entities", region.regionName(rx, rz)))[slot],
    poi: scan.siblingSectorBytes(path.join(dimDir, "poi", region.regionName(rx, rz)))[slot],
  };
  const sets = new Set(slotsOfBitmap(dim.deletions[`r.${rx}.${rz}`] ?? ""));
  out.plannedForDeletion = sets.has(slot);

  const res = region.readChunk(buf, header, slot, path.dirname(file), rx, rz);
  if (!res.ok) return { ...out, readable: false, unreadableReason: res.reason };

  let nbt;
  try {
    nbt = parseNbt(res.data);
  } catch {
    return { ...out, readable: false, unreadableReason: "corrupt" };
  }
  const source = nbt.Level && typeof nbt.Level === "object" ? nbt.Level : nbt;
  const ticks = typeof source.InhabitedTime === "number" ? source.InhabitedTime : null;
  const counts = new Map();
  for (const be of Array.isArray(source.block_entities) ? source.block_entities : []) {
    const id = typeof be?.id === "string" ? be.id : "unknown";
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
  const keysOf = (v) => (v && typeof v === "object" ? Object.keys(v).sort() : []);
  const flags = fastFlags(res.data);

  const spawn = world.readSpawn(worldDir);
  const players = world.readPlayerPositions(worldDir);
  const protectedBy = protectedRects(dimension, plan.params, spawn, players)
    .filter((r) => cx >= r.x1 && cx <= r.x2 && cz >= r.z1 && cz <= r.z2)
    .map((r) => ({ kind: r.kind, ...(r.name ? { name: r.name } : {}) }));

  return {
    ...out,
    readable: true,
    dataVersion: typeof nbt.DataVersion === "number" ? nbt.DataVersion : null,
    status: typeof (source.Status ?? source.status) === "string" ? source.Status ?? source.status : null,
    lastUpdate: typeof source.LastUpdate === "number" ? source.LastUpdate : null,
    inhabitedTicks: ticks,
    inhabitedMinutes: ticks === null ? null : Math.round((ticks / TICKS_PER_MINUTE) * 10) / 10,
    blockEntities: [...counts].map(([id, count]) => ({ id, count })).sort((a, b) => b.count - a.count || a.id.localeCompare(b.id)),
    structureStarts: keysOf(source.structures?.starts),
    structureReferences: keysOf(source.structures?.References),
    signals: SIGNAL_NAMES.filter(([bit]) => flags & bit).map(([, name]) => name),
    unexplained: isUnexplained(flags),
    protectedBy,
  };
}

function fastFlags(data) {
  try {
    return chunkSignals(data).flags;
  } catch {
    return 0;
  }
}

/** "dimension:rx,rz" of every region a plan deletes from. */
function touchedKeys(plan) {
  const keys = new Set();
  for (const dim of plan.dimensions) {
    for (const key of Object.keys(dim.deletions)) {
      const m = /^r\.(-?\d+)\.(-?\d+)$/.exec(key);
      if (m) keys.add(`${dim.id}:${m[1]},${m[2]}`);
    }
  }
  return keys;
}

/** An empty profile for scanWorld; see summarizeProfile in prune-chunks.js. */
function newProfile() {
  return { phases: {}, counts: { chunks: 0, regions: 0, cacheHits: 0, cacheMisses: 0 } };
}

/** A hash of what a plan would delete, independent of when it was made. */
function planHash(plan) {
  const h = crypto.createHash("sha256");
  h.update(JSON.stringify(plan.params));
  for (const dim of plan.dimensions) {
    h.update(dim.id);
    for (const key of Object.keys(dim.deletions).sort()) h.update(`${key}=${dim.deletions[key]};`);
  }
  return h.digest("hex");
}

/**
 * Delete what `plan` names, but only what a fresh scan still agrees on, so a
 * preview made while players were online can remove less than it promised and
 * never more. Fails (deleting nothing) when too little of the plan still holds.
 *
 * @param {{serverPath: string, plan: object, tolerance?: number, onProgress?: Function}} args
 */
function applyPlan({ serverPath, plan, tolerance = 0.1, onProgress, cacheDir = null, reread: rereadOverride = null, timeBudgetMs = 0 }) {
  if (!plan || typeof plan.hash !== "string" || planHash(plan) !== plan.hash) {
    const err = new Error("The plan does not match its own hash.");
    err.code = "plan_invalid";
    throw err;
  }
  // Regions the plan touches are always re-read; the cache only stands in for the rest,
  // which can matter only as neighbours for the buffer.
  const reread = touchedKeys(plan);
  const fresh = scanWorld({ serverPath, params: plan.params, cacheDir, fresh: rereadOverride ?? reread });
  const freshDims = new Map(fresh.plan.dimensions.map((d) => [d.id, d]));

  // What both scans want gone.
  const todo = [];
  let planned = 0;
  let agreed = 0;
  for (const dim of plan.dimensions) {
    const now = freshDims.get(dim.id);
    for (const [key, bitmap] of Object.entries(dim.deletions)) {
      const wanted = slotsOfBitmap(bitmap);
      planned += wanted.length;
      const nowSlots = new Set(now && now.deletions[key] ? slotsOfBitmap(now.deletions[key]) : []);
      const both = wanted.filter((s) => nowSlots.has(s));
      agreed += both.length;
      if (both.length > 0) todo.push({ dim, key, slots: both });
    }
  }
  if (planned === 0) return { deletedChunks: 0, removedFiles: 0, bytesFreed: 0, planned: 0, skippedFiles: 0 };
  if (agreed < planned * (1 - tolerance)) {
    const err = new Error(`Only ${agreed} of ${planned} planned chunks are still unused.`);
    err.code = "plan_stale";
    throw err;
  }

  const worldDir = world.worldDirOf(serverPath);
  let deletedChunks = 0;
  let skippedFiles = 0;
  let removedFiles = 0;
  let bytesFreed = 0;
  const deadline = timeBudgetMs > 0 ? Date.now() + timeBudgetMs : Infinity;
  const cleaned = new Set();

  for (const [index, { dim, key, slots }] of todo.entries()) {
    if (Date.now() > deadline) {
      const err = new Error("The prune ran out of its time budget and stopped before finishing.");
      err.code = "time_budget";
      throw err;
    }
    // The folder comes from the fresh scan, never from the stored plan.
    const freshDim = freshDims.get(dim.id);
    const dimDir = path.join(serverPath, ...freshDim.dir.split("/").filter(Boolean));
    if (!isInside(worldDir, dimDir)) throw new Error("A plan names a folder outside the world.");
    const parsed = /^r\.(-?\d+)\.(-?\d+)$/.exec(key);
    if (!parsed) throw new Error("A plan names an invalid region.");
    const rx = Number(parsed[1]);
    const rz = Number(parsed[2]);

    for (const folder of world.CHUNK_FOLDERS) {
      const dir = path.join(dimDir, folder);
      if (!cleaned.has(dir)) {
        cleaned.add(dir);
        region.removeStaleTemps(dir);
      }
    }

    // A region the engine cannot rewrite safely is left whole, in every folder.
    // All three files are checked before any is touched (S-025): pruning the
    // terrain while a damaged entities or poi file was skipped brought old
    // entities back into the regenerated chunks.
    const regionFile = path.join(dimDir, "region", region.regionName(rx, rz));
    if (!fs.existsSync(regionFile)) {
      skippedFiles++;
      continue;
    }
    const unsafeFolder = world.CHUNK_FOLDERS.find((folder) => {
      const file = path.join(dimDir, folder, region.regionName(rx, rz));
      return fs.existsSync(file) && !region.isSafeToRewrite(file);
    });
    if (unsafeFolder) {
      skippedFiles++;
      continue;
    }

    // Entities and poi first, the region file last: a crash in between loses only
    // entities of chunks that were about to go, never leaves entities pointing at
    // a chunk that was deleted while they were kept.
    for (const folder of [...world.CHUNK_FOLDERS].reverse()) {
      const dir = path.join(dimDir, folder);
      const file = path.join(dir, region.regionName(rx, rz));
      if (!fs.existsSync(file)) continue;
      const res = region.removeChunks(file, slots);
      if (res.unsafe) {
        skippedFiles++;
        continue;
      }
      if (res.removed === 0) continue;
      if (folder === "region") deletedChunks += res.removed;
      for (const slot of res.removedSlots) {
        const ext = path.join(dir, region.externalName(rx * 32 + region.slotX(slot), rz * 32 + region.slotZ(slot)));
        try {
          fs.unlinkSync(ext);
        } catch {
          /* no external file for this chunk */
        }
      }
      if (res.kept === 0) {
        fs.unlinkSync(file);
        removedFiles++;
        bytesFreed += res.bytesBefore;
      } else {
        bytesFreed += res.bytesBefore - res.bytesAfter;
        const problem = region.verifyKept(file, res.keptHashes);
        if (problem) throw new Error(`${path.basename(file)} is wrong after the prune: ${problem}.`);
      }
    }
    if (onProgress) onProgress({ done: index + 1, total: todo.length });
  }

  return { deletedChunks, removedFiles, bytesFreed, planned, skippedFiles };
}

/** True when `child` is `parent` or lies below it. */
function isInside(parent, child) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}

module.exports = {
  CELL,
  isUnexplained,
  isDeletion,
  DEFAULT_PARAMS,
  TICKS_PER_MINUTE,
  normalizeParams,
  scanWorld,
  inspectChunk,
  listScanJobs,
  listDimensions,
  touchedKeys,
  newProfile,
  applyPlan,
  planHash,
  slotsOfBitmap,
};
