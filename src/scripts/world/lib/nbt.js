"use strict";

/**
 * Just enough NBT for pruning: pull a handful of fields out of a chunk without
 * building the whole tree (a chunk is mostly block data that is never needed),
 * and a plain reader for the small player and level files.
 *
 * Big-endian throughout. Longs come back as Numbers; every value this reads
 * (InhabitedTime, LastUpdate) is far below 2^53.
 */

const TAG = {
  END: 0,
  BYTE: 1,
  SHORT: 2,
  INT: 3,
  LONG: 4,
  FLOAT: 5,
  DOUBLE: 6,
  BYTE_ARRAY: 7,
  STRING: 8,
  LIST: 9,
  COMPOUND: 10,
  INT_ARRAY: 11,
  LONG_ARRAY: 12,
};

class NbtError extends Error {}

class Reader {
  constructor(buf) {
    this.buf = buf;
    this.pos = 0;
  }
  need(n) {
    if (this.pos + n > this.buf.length) throw new NbtError("NBT ended early");
  }
  u8() {
    this.need(1);
    return this.buf[this.pos++];
  }
  i8() {
    this.need(1);
    return this.buf.readInt8(this.pos++);
  }
  i16() {
    this.need(2);
    const v = this.buf.readInt16BE(this.pos);
    this.pos += 2;
    return v;
  }
  u16() {
    this.need(2);
    const v = this.buf.readUInt16BE(this.pos);
    this.pos += 2;
    return v;
  }
  i32() {
    this.need(4);
    const v = this.buf.readInt32BE(this.pos);
    this.pos += 4;
    return v;
  }
  i64() {
    this.need(8);
    const v = Number(this.buf.readBigInt64BE(this.pos));
    this.pos += 8;
    return v;
  }
  f32() {
    this.need(4);
    const v = this.buf.readFloatBE(this.pos);
    this.pos += 4;
    return v;
  }
  f64() {
    this.need(8);
    const v = this.buf.readDoubleBE(this.pos);
    this.pos += 8;
    return v;
  }
  string() {
    const len = this.u16();
    this.need(len);
    const s = this.buf.toString("utf8", this.pos, this.pos + len);
    this.pos += len;
    return s;
  }
}

/** Advance past a value of `type` without decoding it. */
function skip(r, type) {
  switch (type) {
    case TAG.BYTE:
      r.need(1);
      r.pos += 1;
      return;
    case TAG.SHORT:
      r.need(2);
      r.pos += 2;
      return;
    case TAG.INT:
    case TAG.FLOAT:
      r.need(4);
      r.pos += 4;
      return;
    case TAG.LONG:
    case TAG.DOUBLE:
      r.need(8);
      r.pos += 8;
      return;
    case TAG.BYTE_ARRAY: {
      const n = r.i32();
      r.need(n);
      r.pos += n;
      return;
    }
    case TAG.STRING: {
      const n = r.u16();
      r.need(n);
      r.pos += n;
      return;
    }
    case TAG.LIST: {
      const inner = r.u8();
      const n = r.i32();
      if (inner === TAG.END || n <= 0) return;
      for (let i = 0; i < n; i++) skip(r, inner);
      return;
    }
    case TAG.COMPOUND:
      for (;;) {
        const t = r.u8();
        if (t === TAG.END) return;
        r.string();
        skip(r, t);
      }
    case TAG.INT_ARRAY: {
      const n = r.i32();
      r.need(n * 4);
      r.pos += n * 4;
      return;
    }
    case TAG.LONG_ARRAY: {
      const n = r.i32();
      r.need(n * 8);
      r.pos += n * 8;
      return;
    }
    default:
      throw new NbtError(`Unknown NBT tag ${type}`);
  }
}

/** Decode a value of `type` into plain JS (compounds become objects, lists arrays). */
function read(r, type) {
  switch (type) {
    case TAG.BYTE:
      return r.i8();
    case TAG.SHORT:
      return r.i16();
    case TAG.INT:
      return r.i32();
    case TAG.LONG:
      return r.i64();
    case TAG.FLOAT:
      return r.f32();
    case TAG.DOUBLE:
      return r.f64();
    case TAG.STRING:
      return r.string();
    case TAG.BYTE_ARRAY: {
      const n = r.i32();
      r.need(n);
      const out = Array.from(r.buf.subarray(r.pos, r.pos + n));
      r.pos += n;
      return out;
    }
    case TAG.INT_ARRAY: {
      const n = r.i32();
      const out = new Array(n);
      for (let i = 0; i < n; i++) out[i] = r.i32();
      return out;
    }
    case TAG.LONG_ARRAY: {
      const n = r.i32();
      const out = new Array(n);
      for (let i = 0; i < n; i++) out[i] = r.i64();
      return out;
    }
    case TAG.LIST: {
      const inner = r.u8();
      const n = r.i32();
      const out = [];
      for (let i = 0; i < n; i++) out.push(read(r, inner));
      return out;
    }
    case TAG.COMPOUND: {
      const out = {};
      for (;;) {
        const t = r.u8();
        if (t === TAG.END) return out;
        out[r.string()] = read(r, t);
      }
    }
    default:
      throw new NbtError(`Unknown NBT tag ${type}`);
  }
}

/** The whole tree of a (small) NBT document, as a plain object. */
function parseNbt(buf) {
  const r = new Reader(buf);
  const type = r.u8();
  if (type !== TAG.COMPOUND) throw new NbtError("NBT root is not a compound");
  r.string();
  return read(r, TAG.COMPOUND);
}

const ROOT_FIELDS = new Set(["InhabitedTime", "LastUpdate", "xPos", "zPos", "DataVersion", "Status"]);

function pickFields(r, found, descend) {
  for (;;) {
    const type = r.u8();
    if (type === TAG.END) return;
    const name = r.string();
    if (ROOT_FIELDS.has(name) && (type === TAG.LONG || type === TAG.INT || type === TAG.STRING)) {
      found[name] = read(r, type);
    } else if (descend && name === "Level" && type === TAG.COMPOUND) {
      pickFields(r, found, false);
    } else {
      skip(r, type);
    }
  }
}

/**
 * The fields pruning decides on, from a chunk's NBT. Works for both layouts:
 * the flat root of 1.18 and later, and the `Level` compound before it.
 * Everything else is skipped without decoding.
 *
 * @returns {{InhabitedTime?: number, LastUpdate?: number, xPos?: number, zPos?: number, DataVersion?: number, Status?: string}}
 */
function chunkMeta(buf) {
  const r = new Reader(buf);
  const type = r.u8();
  if (type !== TAG.COMPOUND) throw new NbtError("Chunk root is not a compound");
  r.string();
  const found = {};
  pickFields(r, found, true);
  return found;
}

module.exports = { TAG, NbtError, parseNbt, chunkMeta };
