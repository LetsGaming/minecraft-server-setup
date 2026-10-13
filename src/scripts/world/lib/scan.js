"use strict";

/**
 * Reading one region file into a compact record. A record depends on the file
 * alone (never on the prune parameters), which is what makes it cacheable: a
 * different threshold, radius or buffer is a recompute over records, not a rescan.
 */

const fs = require("fs");
const path = require("path");
const { inhabitedTime } = require("./nbt");
const region = require("./region");

/** Per-slot state of a chunk in a record. */
const STATE = { EMPTY: 0, OK: 1, UNREADABLE: 2 };

/**
 * @typedef {object} RegionRecord
 * @property {Uint8Array} state    STATE per slot
 * @property {Float64Array} ticks  InhabitedTime per slot (0 unless state is OK)
 * @property {Uint32Array} bytes   sector bytes the chunk occupies in the region file
 */

/**
 * Read and decode every chunk of a region file. Never throws for bad chunk
 * data: an unreadable chunk is recorded as such. Returns null when the file
 * cannot be read at all or holds no chunk.
 *
 * @returns {RegionRecord | null}
 */
function readRegionRecord(file, rx, rz, timed = (_n, fn) => fn(), onChunk = () => {}) {
  let buf;
  try {
    buf = timed("read", () => fs.readFileSync(file));
  } catch {
    return null;
  }
  const header = timed("header", () => region.readHeader(buf));
  if (!header) return null;

  const state = new Uint8Array(region.CHUNKS);
  const ticks = new Float64Array(region.CHUNKS);
  const bytes = new Uint32Array(region.CHUNKS);
  const dir = path.dirname(file);
  let any = false;

  for (const slot of region.occupiedSlots(header)) {
    any = true;
    onChunk();
    bytes[slot] = region.sectorCount(header.locations[slot]) * region.SECTOR;
    const res = timed("inflate", () => region.readChunk(buf, header, slot, dir, rx, rz));
    if (!res.ok) {
      state[slot] = STATE.UNREADABLE;
      continue;
    }
    let inhabited;
    try {
      inhabited = timed("nbt", () => inhabitedTime(res.data));
    } catch {
      state[slot] = STATE.UNREADABLE;
      continue;
    }
    // A chunk with no InhabitedTime at all is not known to be unused.
    if (typeof inhabited !== "number") {
      state[slot] = STATE.UNREADABLE;
      continue;
    }
    state[slot] = STATE.OK;
    ticks[slot] = inhabited;
  }
  return any ? { state, ticks, bytes } : null;
}

/** Sector bytes per slot of a sibling folder's file (entities, poi); all zero when absent. */
function siblingSectorBytes(file) {
  const out = new Uint32Array(region.CHUNKS);
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const head = Buffer.alloc(region.HEADER);
    if (fs.readSync(fd, head, 0, region.HEADER, 0) < region.HEADER) return out;
    for (let slot = 0; slot < region.CHUNKS; slot++) {
      out[slot] = region.sectorCount(head.readUInt32BE(slot * 4)) * region.SECTOR;
    }
  } catch {
    /* no sibling file: nothing to count */
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  return out;
}

module.exports = { STATE, readRegionRecord, siblingSectorBytes };
