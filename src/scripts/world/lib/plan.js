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
const { chunkMeta } = require("./nbt");
const region = require("./region");
const world = require("./world");

const TICKS_PER_MINUTE = 20 * 60;

/** What each chunk cell is, for the map and for the decision. */
const CELL = {
  EMPTY: 0,
  DELETE: 1,
  ACTIVE: 2,
  PROTECTED: 3,
  BUFFER: 4,
  UNREADABLE: 5,
};

const DEFAULT_PARAMS = Object.freeze({
  thresholdMinutes: 5,
  spawnRadiusChunks: 16,
  playerRadiusChunks: 8,
  bufferChunks: 2,
  zones: [],
  dimensions: null,
});

/** More cells than this and the world is too spread out to hold as a grid. */
const MAX_GRID_CELLS = 250_000_000;

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
    rects.push({ x1: cx - r, z1: cz - r, x2: cx + r, z2: cz + r });
  }
  if (params.playerRadiusChunks > 0) {
    for (const p of players) {
      if (p.dimension !== dimId) continue;
      const cx = blockToChunk(p.x);
      const cz = blockToChunk(p.z);
      const r = params.playerRadiusChunks;
      rects.push({ x1: cx - r, z1: cz - r, x2: cx + r, z2: cz + r });
    }
  }
  for (const z of params.zones) {
    if (z.dimension === dimId) rects.push({ x1: z.x1, z1: z.z1, x2: z.x2, z2: z.z2 });
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

/** Sector bytes a slot occupies in a sibling folder's file, 0 when absent. */
function slotBytes(file, slot) {
  try {
    const fd = fs.openSync(file, "r");
    try {
      const head = Buffer.alloc(region.HEADER);
      const n = fs.readSync(fd, head, 0, region.HEADER, 0);
      if (n < region.HEADER) return 0;
      return region.sectorCount(head.readUInt32BE(slot * 4)) * region.SECTOR;
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return 0;
  }
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
function scanDimension({ dimId, dimDir, params, spawn, players, onRegion, profile }) {
  const thresholdTicks = params.thresholdMinutes * TICKS_PER_MINUTE;
  const regions = listRegions(dimDir);
  const cells = new Map(); // "rx,rz" -> {cell:Uint8Array(1024), heat:Uint8Array(1024), bytes:Uint32Array(1024)}

  let minX = Infinity;
  let minZ = Infinity;
  let maxX = -Infinity;
  let maxZ = -Infinity;

  for (const r of regions) {
    let buf;
    try {
      buf = timed(profile, "read", () => fs.readFileSync(r.file));
    } catch {
      continue;
    }
    const header = timed(profile, "header", () => region.readHeader(buf));
    if (!header) continue;
    const cell = new Uint8Array(region.CHUNKS);
    const heat = new Uint8Array(region.CHUNKS);
    const bytes = new Uint32Array(region.CHUNKS);
    let any = false;

    for (const slot of region.occupiedSlots(header)) {
      any = true;
      const loc = header.locations[slot];
      bytes[slot] = region.sectorCount(loc) * region.SECTOR;
      if (profile) profile.counts.chunks++;
      const res = timed(profile, "inflate", () => region.readChunk(buf, header, slot, path.dirname(r.file), r.x, r.z));
      if (!res.ok) {
        cell[slot] = CELL.UNREADABLE;
        continue;
      }
      let meta;
      try {
        meta = timed(profile, "nbt", () => chunkMeta(res.data));
      } catch {
        cell[slot] = CELL.UNREADABLE;
        continue;
      }
      // A chunk with no InhabitedTime at all is not known to be unused.
      if (typeof meta.InhabitedTime !== "number") {
        cell[slot] = CELL.UNREADABLE;
        continue;
      }
      heat[slot] = heatLevel(meta.InhabitedTime / TICKS_PER_MINUTE);
      cell[slot] = meta.InhabitedTime < thresholdTicks ? CELL.DELETE : CELL.ACTIVE;
    }

    if (!any) continue;
    if (profile) profile.counts.regions++;
    cells.set(`${r.x},${r.z}`, { rx: r.x, rz: r.z, cell, heat, bytes, file: r.file });
    minX = Math.min(minX, r.x * 32);
    minZ = Math.min(minZ, r.z * 32);
    maxX = Math.max(maxX, r.x * 32 + 31);
    maxZ = Math.max(maxZ, r.z * 32 + 31);
    if (onRegion) onRegion();
  }

  if (cells.size === 0) return { cells, regions: 0 };

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
    timed(profile, "buffer", () => applyBuffer(cells, { minX, minZ, maxX, maxZ }, params.bufferChunks));
  }

  return { cells, regions: cells.size };
}

const isKeep = (c) => c === CELL.ACTIVE || c === CELL.PROTECTED || c === CELL.UNREADABLE;

function applyBuffer(cells, box, n) {
  const w = box.maxX - box.minX + 1;
  const h = box.maxZ - box.minZ + 1;
  if (w * h > MAX_GRID_CELLS) {
    throw new Error("The world is spread over too large an area to prune with a buffer.");
  }
  const keep = new Uint8Array(w * h);
  for (const entry of cells.values()) {
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      if (!isKeep(entry.cell[slot])) continue;
      const x = entry.rx * 32 + region.slotX(slot) - box.minX;
      const z = entry.rz * 32 + region.slotZ(slot) - box.minZ;
      keep[z * w + x] = 1;
    }
  }
  // Chebyshev distance <= n is a box dilation: one pass along x, one along z.
  const tmp = new Uint8Array(w * h);
  for (let z = 0; z < h; z++) {
    const row = z * w;
    let last = -Infinity;
    for (let x = 0; x < w; x++) {
      if (keep[row + x]) last = x;
      if (x - last <= n) tmp[row + x] = 1;
    }
    last = Infinity;
    for (let x = w - 1; x >= 0; x--) {
      if (keep[row + x]) last = x;
      if (last - x <= n) tmp[row + x] = 1;
    }
  }
  const out = new Uint8Array(w * h);
  for (let x = 0; x < w; x++) {
    let last = -Infinity;
    for (let z = 0; z < h; z++) {
      if (tmp[z * w + x]) last = z;
      if (z - last <= n) out[z * w + x] = 1;
    }
    last = Infinity;
    for (let z = h - 1; z >= 0; z--) {
      if (tmp[z * w + x]) last = z;
      if (last - z <= n) out[z * w + x] = 1;
    }
  }
  for (const entry of cells.values()) {
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      if (entry.cell[slot] !== CELL.DELETE) continue;
      const x = entry.rx * 32 + region.slotX(slot) - box.minX;
      const z = entry.rz * 32 + region.slotZ(slot) - box.minZ;
      if (out[z * w + x]) entry.cell[slot] = CELL.BUFFER;
    }
  }
}

const b64 = (typed) => Buffer.from(typed.buffer, typed.byteOffset, typed.byteLength).toString("base64");

function deletionBitmap(cell) {
  const bits = new Uint8Array(region.CHUNKS / 8);
  let count = 0;
  for (let slot = 0; slot < region.CHUNKS; slot++) {
    if (cell[slot] === CELL.DELETE) {
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
function scanWorld({ serverPath, params: rawParams, onProgress, profile }) {
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
    const { cells } = scanDimension({
      dimId: dim.id,
      dimDir: dim.dir,
      params,
      spawn,
      players,
      onRegion: onProgress,
      profile,
    });

    const counts = { chunks: 0, delete: 0, active: 0, protected: 0, buffer: 0, unreadable: 0 };
    const deletions = {};
    const mapRegions = {};
    let bytes = 0;
    let regionsEmptied = 0;

    const tAssemble = profile ? process.hrtime.bigint() : 0n;
    for (const entry of [...cells.values()].sort((a, b) => a.rx - b.rx || a.rz - b.rz)) {
      const key = `r.${entry.rx}.${entry.rz}`;
      mapRegions[key] = { cell: b64(entry.cell), heat: b64(entry.heat) };
      const { bits, count } = deletionBitmap(entry.cell);
      let occupied = 0;
      for (let slot = 0; slot < region.CHUNKS; slot++) {
        const c = entry.cell[slot];
        if (c === CELL.EMPTY) continue;
        occupied++;
        if (c === CELL.ACTIVE) counts.active++;
        else if (c === CELL.PROTECTED) counts.protected++;
        else if (c === CELL.BUFFER) counts.buffer++;
        else if (c === CELL.UNREADABLE) counts.unreadable++;
        if (c === CELL.DELETE) {
          bytes += entry.bytes[slot];
          for (const folder of ["entities", "poi"]) {
            bytes += timed(profile, "slotBytes", () => slotBytes(path.join(dim.dir, folder, region.regionName(entry.rx, entry.rz)), slot));
          }
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

/** An empty profile for scanWorld; see summarizeProfile in prune-chunks.js. */
function newProfile() {
  return { phases: {}, counts: { chunks: 0, regions: 0 } };
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
function applyPlan({ serverPath, plan, tolerance = 0.1, onProgress }) {
  if (!plan || typeof plan.hash !== "string" || planHash(plan) !== plan.hash) {
    const err = new Error("The plan does not match its own hash.");
    err.code = "plan_invalid";
    throw err;
  }
  const fresh = scanWorld({ serverPath, params: plan.params });
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
  const touched = [];

  for (const { dim, key, slots } of todo) {
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
      const file = path.join(dir, region.regionName(rx, rz));
      if (!fs.existsSync(file)) continue;
      const res = region.removeChunks(file, slots);
      if (res.unsafe) {
        skippedFiles++;
        if (folder === "region") break;
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
        touched.push({ file, keptHashes: res.keptHashes });
      }
    }
    if (onProgress) onProgress();
  }

  validate(touched);
  return { deletedChunks, removedFiles, bytesFreed, planned, skippedFiles };
}

/** Every chunk kept in a rewritten region file must be byte for byte what was copied. */
function validate(touched) {
  for (const t of touched) {
    const problem = region.verifyKept(t.file, t.keptHashes);
    if (problem) throw new Error(`${path.basename(t.file)} is wrong after the prune: ${problem}.`);
  }
}

/** True when `child` is `parent` or lies below it. */
function isInside(parent, child) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}

module.exports = {
  CELL,
  DEFAULT_PARAMS,
  TICKS_PER_MINUTE,
  normalizeParams,
  scanWorld,
  newProfile,
  applyPlan,
  planHash,
  slotsOfBitmap,
};
