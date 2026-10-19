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
const crypto = require("crypto");

const SECTOR = 4096;
const HEADER = 2 * SECTOR;
const CHUNKS = 1024;

const COMPRESSION = { GZIP: 1, ZLIB: 2, NONE: 3, LZ4: 4 };
const EXTERNAL_FLAG = 128;
/** Most bytes a chunk may inflate to, or an external (.mcc) chunk file may hold. */
const MAX_CHUNK_BYTES = 64 * 1024 * 1024;

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
  if (sectorCount(loc) === 0) return { ok: false, reason: "corrupt" };
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
      const file = path.join(dir, externalName(cx, cz));
      if (fs.statSync(file).size > MAX_CHUNK_BYTES) return { ok: false, reason: "corrupt" };
      payload = fs.readFileSync(file);
    } catch {
      return { ok: false, reason: "external" };
    }
  }

  try {
    // A chunk is a few hundred KB; a stream that inflates past the cap is a
    // decompression bomb or damage, and either way the chunk is left alone.
    const limit = { maxOutputLength: MAX_CHUNK_BYTES };
    if (type === COMPRESSION.ZLIB) return { ok: true, data: zlib.inflateSync(payload, limit) };
    if (type === COMPRESSION.GZIP) return { ok: true, data: zlib.gunzipSync(payload, limit) };
    if (type === COMPRESSION.NONE) {
      if (payload.length > MAX_CHUNK_BYTES) return { ok: false, reason: "corrupt" };
      return { ok: true, data: Buffer.from(payload) };
    }
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
 * Slots whose header entry cannot be trusted: no sectors, a start inside the
 * header, or sectors that overlap another chunk's. Rewriting around such a
 * file could alias or lose data, so callers leave it alone.
 */
function unsafeSlots(header) {
  const bad = new Set();
  const spans = [];
  for (const slot of occupiedSlots(header)) {
    const loc = header.locations[slot];
    const start = sectorOffset(loc);
    const count = sectorCount(loc);
    if (count === 0 || start < 2) bad.add(slot);
    else spans.push({ slot, start, end: start + count });
  }
  spans.sort((a, b) => a.start - b.start);
  for (let i = 1; i < spans.length; i++) {
    if (spans[i].start < spans[i - 1].end) {
      bad.add(spans[i].slot);
      bad.add(spans[i - 1].slot);
    }
  }
  return bad;
}

const sha1 = (b) => crypto.createHash("sha1").update(b).digest("hex");

/**
 * Rewrite a region file without the given slots, compacting what is left so the
 * space comes back. Chunk bytes are copied as they are, never re-encoded.
 * Returns the number of chunks kept; 0 means the file holds nothing any more
 * and the caller should delete it. Written beside the original and renamed over
 * it, so a crash leaves either the old file or the new one.
 *
 * A file whose header cannot be trusted (see unsafeSlots) is left untouched and
 * reported with `unsafe: true`. `keptHashes` maps every kept slot to a digest of
 * the sector bytes written for it, for verifyKept.
 *
 * @returns {{kept: number, removed: number, removedSlots: number[], bytesBefore: number, bytesAfter: number, unsafe?: boolean, keptHashes?: Record<number, string>}}
 */
function removeChunks(file, slotsToRemove) {
  const buf = fs.readFileSync(file);
  const header = readHeader(buf);
  if (!header) return { kept: 0, removed: 0, removedSlots: [], bytesBefore: buf.length, bytesAfter: 0 };

  if (unsafeSlots(header).size > 0) {
    return { kept: 0, removed: 0, removedSlots: [], bytesBefore: buf.length, bytesAfter: 0, unsafe: true };
  }

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
  const keptHashes = {};
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
    keptHashes[slot] = sha1(padded);
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
  try {
    writeDurably(tmp, result);
    fs.renameSync(tmp, file);
  } catch (err) {
    // A full disk or a failed rename must not leave a half-written copy behind.
    fs.rmSync(tmp, { force: true });
    throw err;
  }
  syncDirectory(path.dirname(file));
  return {
    kept: keep.length,
    removed: removedSlots.length,
    removedSlots,
    bytesBefore: buf.length,
    bytesAfter: result.length,
    keptHashes,
  };
}

/** Write a file and flush it to disk before it can be renamed over anything. */
function writeDurably(file, data) {
  const fd = fs.openSync(file, "w");
  try {
    fs.writeSync(fd, data, 0, data.length, 0);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

/** Flush a directory entry (the rename). Not possible on Windows, where it is skipped. */
function syncDirectory(dir) {
  let fd;
  try {
    fd = fs.openSync(dir, "r");
    fs.fsyncSync(fd);
  } catch {
    /* unsupported here; the rename itself is still atomic */
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** True when a region file can be compacted without aliasing or losing a chunk. */
function isSafeToRewrite(file) {
  try {
    const header = readHeader(fs.readFileSync(file));
    return header === null || unsafeSlots(header).size === 0;
  } catch {
    return false;
  }
}

/** Remove temp files an interrupted rewrite left beside the region files in `dir`. */
function removeStaleTemps(dir) {
  let removed = 0;
  let names = [];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return 0;
  }
  for (const name of names) {
    if (/\.mca\.prune-\d+\.tmp$/.test(name)) {
      fs.rmSync(path.join(dir, name), { force: true });
      removed++;
    }
  }
  return removed;
}

/**
 * Check a rewritten file against what removeChunks wrote: a header that parses
 * and every kept chunk's sectors byte for byte as copied. Chunks that were
 * already unreadable are kept as they were and are not this function's concern.
 *
 * @returns {string | null} a description of the first mismatch, or null
 */
function verifyKept(file, keptHashes) {
  const buf = fs.readFileSync(file);
  const header = readHeader(buf);
  if (!header) return "no header";
  const slots = occupiedSlots(header);
  const expected = Object.keys(keptHashes);
  if (slots.length !== expected.length) return `${slots.length} chunks instead of ${expected.length}`;
  for (const slot of slots) {
    const want = keptHashes[slot];
    if (!want) return `slot ${slot} was not kept`;
    const loc = header.locations[slot];
    const from = sectorOffset(loc) * SECTOR;
    const chunk = buf.subarray(from, from + sectorCount(loc) * SECTOR);
    if (sha1(chunk) !== want) return `slot ${slot} differs from the original`;
  }
  return null;
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
  verifyKept,
  unsafeSlots,
  isSafeToRewrite,
  removeStaleTemps,
  sectorOffset,
  sectorCount,
  MAX_CHUNK_BYTES,
};
