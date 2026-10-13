"use strict";

/**
 * Persistent per-region records, so a second scan only reads regions whose
 * file changed. An entry is a pure function of the region file: it is valid
 * exactly when the file's fingerprint (size, mtime and a digest of the 8 KiB
 * header) matches, and a format version guards the layout. Anything that does
 * not parse is treated as a miss, never as an error.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const region = require("./region");

const VERSION = 1;
const MAGIC = 0x50524e43; // "PRNC"
const FP_BYTES = 20;
const BODY = region.CHUNKS * (1 + 4 + 8);
const SIZE = 4 + 4 + FP_BYTES + BODY;

/**
 * Fingerprint of a region file, or null when it cannot be read.
 * @returns {Buffer | null}
 */
function fingerprint(file) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const st = fs.fstatSync(fd);
    const head = Buffer.alloc(Math.min(region.HEADER, st.size));
    fs.readSync(fd, head, 0, head.length, 0);
    const h = crypto.createHash("sha1");
    h.update(`${st.size}:${st.mtimeMs}:`);
    h.update(head);
    return h.digest();
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

const entryFile = (dir, dimId, rx, rz) => path.join(dir, dimId, `r.${rx}.${rz}.meta`);

/** The cached record for a region if its fingerprint still matches. */
function load(dir, dimId, rx, rz, fp) {
  if (!fp) return null;
  let buf;
  try {
    buf = fs.readFileSync(entryFile(dir, dimId, rx, rz));
  } catch {
    return null;
  }
  if (buf.length !== SIZE || buf.readUInt32BE(0) !== MAGIC || buf.readUInt32BE(4) !== VERSION) return null;
  if (!buf.subarray(8, 8 + FP_BYTES).equals(fp)) return null;
  const body = buf.subarray(8 + FP_BYTES);
  const n = region.CHUNKS;
  const state = new Uint8Array(body.subarray(0, n));
  const bytes = new Uint32Array(n);
  const ticks = new Float64Array(n);
  for (let i = 0; i < n; i++) bytes[i] = body.readUInt32BE(n + i * 4);
  for (let i = 0; i < n; i++) ticks[i] = body.readDoubleBE(n + n * 4 + i * 8);
  return { state, ticks, bytes };
}

/** Store a record under the fingerprint it was read with. Best effort: a failed write only costs a later rescan. */
function store(dir, dimId, rx, rz, fp, record) {
  if (!fp) return;
  const n = region.CHUNKS;
  const buf = Buffer.alloc(SIZE);
  buf.writeUInt32BE(MAGIC, 0);
  buf.writeUInt32BE(VERSION, 4);
  fp.copy(buf, 8);
  const body = buf.subarray(8 + FP_BYTES);
  Buffer.from(record.state.buffer, record.state.byteOffset, n).copy(body, 0);
  for (let i = 0; i < n; i++) body.writeUInt32BE(record.bytes[i], n + i * 4);
  for (let i = 0; i < n; i++) body.writeDoubleBE(record.ticks[i], n + n * 4 + i * 8);
  const file = entryFile(dir, dimId, rx, rz);
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(tmp, buf, { mode: 0o600 });
    fs.renameSync(tmp, file);
  } catch {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      /* nothing to clean */
    }
  }
}

/** Drop entries for regions that no longer exist in a dimension. */
function prune(dir, dimId, liveKeys) {
  let names;
  try {
    names = fs.readdirSync(path.join(dir, dimId));
  } catch {
    return;
  }
  for (const name of names) {
    const m = /^r\.(-?\d+)\.(-?\d+)\.meta$/.exec(name);
    if (m && !liveKeys.has(`${m[1]},${m[2]}`)) fs.rmSync(path.join(dir, dimId, name), { force: true });
  }
}

module.exports = { VERSION, fingerprint, load, store, prune };
