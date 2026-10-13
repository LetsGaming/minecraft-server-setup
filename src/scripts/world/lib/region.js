"use strict";

/**
 * Reading and rewriting Anvil region files (r.X.Z.mca).
 *
 * Layout: an 8 KiB header of 1024 location entries (3 bytes sector offset,
 * 1 byte sector count) and 1024 timestamps, then chunk data in 4 KiB sectors.
 * A chunk is a 4 byte length, a compression byte and the payload. Compression
 * 1 is gzip, 2 zlib, 3 none, 4 LZ4 (1.20.5+). Bit 7 of the compression byte
 * means the payload lives in a separate c.X.Z.mcc file.
 *
 * Deleting a chunk is zeroing its two header entries; the file is then
 * compacted so the space is actually returned.
 */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const SECTOR = 4096;
const HEADER = 2 * SECTOR;
const CHUNKS = 1024;

const COMPRESSION = { GZIP: 1, ZLIB: 2, NONE: 3, LZ4: 4 };
const EXTERNAL_FLAG = 128;

/** r.X.Z.mca to {x, z}, or null for any other name. */
function parseRegionName(name) {
  const m = /^r\.(-?\d+)\.(-?\d+)\.mca$/.exec(name);
  return m ? { x: Number(m[1]), z: Number(m[2]) } : null;
}

const regionName = (rx, rz) => `r.${rx}.${rz}.mca`;
const externalName = (cx, cz) => `c.${cx}.${cz}.mcc`;

/** Chunk slot (0..1023) to its offset inside the region, in chunks. */
const slotX = (slot) => slot & 31;
const slotZ = (slot) => slot >> 5;
const slotOf = (x, z) => (x & 31) + (z & 31) * 32;

/**
 * Header of a region file: where each chunk lives. `null` for a file too short
 * to hold one (a freshly created or damaged file), which callers treat as empty.
 */
function readHeader(buf) {
  if (buf.length < HEADER) return null;
  const locations = new Uint32Array(CHUNKS);
  const timestamps = new Uint32Array(CHUNKS);
  for (let i = 0; i < CHUNKS; i++) {
    locations[i] = buf.readUInt32BE(i * 4);
    timestamps[i] = buf.readUInt32BE(SECTOR + i * 4);
  }
  return { locations, timestamps };
}

const sectorOffset = (loc) => loc >>> 8;
const sectorCount = (loc) => loc & 0xff;

/**
 * Chunk payload bytes for a slot, decompressed, or a reason it cannot be read.
 * Never throws: an unreadable chunk is data about the world, not a crash.
 *
 * @returns {{ok: true, data: Buffer} | {ok: false, reason: "empty"|"truncated"|"lz4"|"external"|"corrupt"}}
 */
function readChunk(buf, header, slot, dir, regionX, regionZ) {
  const loc = header.locations[slot];
  if (loc === 0) return { ok: false, reason: "empty" };
  const start = sectorOffset(loc) * SECTOR;
  if (start < HEADER || start + 5 > buf.length) return { ok: false, reason: "truncated" };
  const length = buf.readUInt32BE(start);
  if (length < 1 || start + 4 + length > buf.length) return { ok: false, reason: "truncated" };
  const compression = buf[start + 4];
  let payload = buf.subarray(start + 5, start + 4 + length);
  const type = compression & ~EXTERNAL_FLAG;

  if (compression & EXTERNAL_FLAG) {
    if (!dir) return { ok: false, reason: "external" };
    const cx = regionX * 32 + slotX(slot);
    const cz = regionZ * 32 + slotZ(slot);
    try {
      payload = fs.readFileSync(path.join(dir, externalName(cx, cz)));
    } catch {
      return { ok: false, reason: "external" };
    }
  }

  try {
    if (type === COMPRESSION.ZLIB) return { ok: true, data: zlib.inflateSync(payload) };
    if (type === COMPRESSION.GZIP) return { ok: true, data: zlib.gunzipSync(payload) };
    if (type === COMPRESSION.NONE) return { ok: true, data: Buffer.from(payload) };
  } catch {
    return { ok: false, reason: "corrupt" };
  }
  if (type === COMPRESSION.LZ4) return { ok: false, reason: "lz4" };
  return { ok: false, reason: "corrupt" };
}

/** Slots that hold a chunk, in file order. */
function occupiedSlots(header) {
  const out = [];
  for (let i = 0; i < CHUNKS; i++) if (header.locations[i] !== 0) out.push(i);
  return out;
}

/**
 * Rewrite a region file without the given slots, compacting what is left so the
 * space comes back. Chunk bytes are copied as they are, never re-encoded.
 * Returns the number of chunks kept; 0 means the file holds nothing any more
 * and the caller should delete it. Written beside the original and renamed over
 * it, so a crash leaves either the old file or the new one.
 *
 * @returns {{kept: number, removed: number, removedSlots: number[], bytesBefore: number, bytesAfter: number}}
 */
function removeChunks(file, slotsToRemove) {
  const buf = fs.readFileSync(file);
  const header = readHeader(buf);
  if (!header) return { kept: 0, removed: 0, removedSlots: [], bytesBefore: buf.length, bytesAfter: 0 };

  const drop = new Set(slotsToRemove);
  const keep = [];
  const removedSlots = [];
  for (const slot of occupiedSlots(header)) {
    if (drop.has(slot)) {
      removedSlots.push(slot);
    } else {
      keep.push(slot);
    }
  }
  if (keep.length === 0) {
    return { kept: 0, removed: removedSlots.length, removedSlots, bytesBefore: buf.length, bytesAfter: 0 };
  }

  const parts = [];
  const locations = new Uint32Array(CHUNKS);
  const timestamps = new Uint32Array(CHUNKS);
  let next = 2;
  for (const slot of keep) {
    const loc = header.locations[slot];
    const from = sectorOffset(loc) * SECTOR;
    const sectors = sectorCount(loc);
    // A chunk whose sectors run past the end is read as far as it goes; its
    // header entry keeps pointing at the new, shorter place.
    const chunk = buf.subarray(from, Math.min(buf.length, from + sectors * SECTOR));
    const padded = Buffer.alloc(sectors * SECTOR);
    chunk.copy(padded);
    parts.push(padded);
    locations[slot] = (next << 8) | sectors;
    timestamps[slot] = header.timestamps[slot];
    next += sectors;
  }

  const out = Buffer.alloc(HEADER);
  for (let i = 0; i < CHUNKS; i++) {
    out.writeUInt32BE(locations[i], i * 4);
    out.writeUInt32BE(timestamps[i], SECTOR + i * 4);
  }
  const result = Buffer.concat([out, ...parts]);

  const tmp = `${file}.prune-${process.pid}.tmp`;
  fs.writeFileSync(tmp, result);
  fs.renameSync(tmp, file);
  return {
    kept: keep.length,
    removed: removedSlots.length,
    removedSlots,
    bytesBefore: buf.length,
    bytesAfter: result.length,
  };
}

module.exports = {
  SECTOR,
  HEADER,
  CHUNKS,
  COMPRESSION,
  EXTERNAL_FLAG,
  parseRegionName,
  regionName,
  externalName,
  slotX,
  slotZ,
  slotOf,
  readHeader,
  readChunk,
  occupiedSlots,
  removeChunks,
  sectorOffset,
  sectorCount,
};
