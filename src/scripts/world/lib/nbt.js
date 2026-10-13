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
    if (n < 0 || this.pos + n > this.buf.length) throw new NbtError("NBT ended early");
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

// ── Fast path: InhabitedTime only ──

const INHABITED = Buffer.from("InhabitedTime");
const LEVEL = Buffer.from("Level");

function overrun() {
  return new NbtError("NBT ended early");
}

/** Position after a value of `type` that starts at `pos`. Names and strings are never decoded. */
function skipAt(buf, pos, type) {
  const end = buf.length;
  switch (type) {
    case TAG.BYTE:
      pos += 1;
      break;
    case TAG.SHORT:
      pos += 2;
      break;
    case TAG.INT:
    case TAG.FLOAT:
      pos += 4;
      break;
    case TAG.LONG:
    case TAG.DOUBLE:
      pos += 8;
      break;
    case TAG.STRING:
      if (pos + 2 > end) throw overrun();
      pos += 2 + buf.readUInt16BE(pos);
      break;
    case TAG.BYTE_ARRAY:
    case TAG.INT_ARRAY:
    case TAG.LONG_ARRAY: {
      if (pos + 4 > end) throw overrun();
      const len = buf.readInt32BE(pos);
      if (len < 0) throw overrun();
      pos += 4 + len * (type === TAG.BYTE_ARRAY ? 1 : type === TAG.INT_ARRAY ? 4 : 8);
      break;
    }
    case TAG.LIST: {
      if (pos + 5 > end) throw overrun();
      const inner = buf[pos];
      const count = buf.readInt32BE(pos + 1);
      pos += 5;
      if (inner === TAG.END || count <= 0) break;
      // Fixed-size elements need no walk.
      const size = FIXED_SIZE[inner];
      if (size !== undefined) {
        pos += count * size;
        break;
      }
      for (let i = 0; i < count; i++) pos = skipAt(buf, pos, inner);
      break;
    }
    case TAG.COMPOUND:
      for (;;) {
        if (pos >= end) throw overrun();
        const t = buf[pos++];
        if (t === TAG.END) return pos;
        if (pos + 2 > end) throw overrun();
        pos += 2 + buf.readUInt16BE(pos);
        pos = skipAt(buf, pos, t);
      }
    default:
      throw new NbtError(`Unknown NBT tag ${type}`);
  }
  if (pos > end) throw overrun();
  return pos;
}

const FIXED_SIZE = { [TAG.BYTE]: 1, [TAG.SHORT]: 2, [TAG.INT]: 4, [TAG.FLOAT]: 4, [TAG.LONG]: 8, [TAG.DOUBLE]: 8 };

/** InhabitedTime of a chunk (either layout), or undefined when the chunk has none. Stops at the first hit. */
function inhabitedTime(buf) {
  if (buf.length < 3 || buf[0] !== TAG.COMPOUND) throw new NbtError("Chunk root is not a compound");
  let pos = 3 + buf.readUInt16BE(1);
  const end = buf.length;
  let inLevel = false;
  for (;;) {
    if (pos >= end) throw overrun();
    const type = buf[pos++];
    if (type === TAG.END) {
      if (!inLevel) return undefined;
      inLevel = false; // end of Level: the root's own END follows
      continue;
    }
    if (pos + 2 > end) throw overrun();
    const nameLen = buf.readUInt16BE(pos);
    const nameAt = pos + 2;
    pos = nameAt + nameLen;
    if (pos > end) throw overrun();
    if (type === TAG.LONG && nameLen === INHABITED.length && buf.compare(INHABITED, 0, nameLen, nameAt, pos) === 0) {
      if (pos + 8 > end) throw overrun();
      return buf.readInt32BE(pos) * 4294967296 + buf.readUInt32BE(pos + 4);
    }
    if (!inLevel && type === TAG.COMPOUND && nameLen === LEVEL.length && buf.compare(LEVEL, 0, nameLen, nameAt, pos) === 0) {
      inLevel = true;
      continue;
    }
    pos = skipAt(buf, pos, type);
  }
}

// ── Signals: what a chunk contains that hints at a player's hand ──

/** Bits of the `flags` that chunkSignals returns and the record cache stores. */
const SIGNAL = {
  CONTAINER: 1,
  SIGN: 2,
  FURNACE: 4,
  BED: 8,
  REDSTONE: 16,
  OTHER_BLOCK_ENTITY: 32,
  SPAWNER: 64,
  STRUCTURE_START: 128,
  STRUCTURE_REFERENCE: 256,
  NOT_FULL: 512,
};

const BLOCK_ENTITY_KIND = new Map([
  ["chest", SIGNAL.CONTAINER],
  ["trapped_chest", SIGNAL.CONTAINER],
  ["barrel", SIGNAL.CONTAINER],
  ["shulker_box", SIGNAL.CONTAINER],
  ["sign", SIGNAL.SIGN],
  ["hanging_sign", SIGNAL.SIGN],
  ["furnace", SIGNAL.FURNACE],
  ["blast_furnace", SIGNAL.FURNACE],
  ["smoker", SIGNAL.FURNACE],
  ["bed", SIGNAL.BED],
  ["hopper", SIGNAL.REDSTONE],
  ["dispenser", SIGNAL.REDSTONE],
  ["dropper", SIGNAL.REDSTONE],
  ["comparator", SIGNAL.REDSTONE],
  ["daylight_detector", SIGNAL.REDSTONE],
  ["command_block", SIGNAL.REDSTONE],
  ["mob_spawner", SIGNAL.SPAWNER],
  ["trial_spawner", SIGNAL.SPAWNER],
]);

/** Signal bit for a block entity id such as "minecraft:chest". */
function blockEntityKind(id) {
  const name = id.startsWith("minecraft:") ? id.slice(10) : id;
  return BLOCK_ENTITY_KIND.get(name) ?? SIGNAL.OTHER_BLOCK_ENTITY;
}

const eq = (buf, at, len, bytes) => len === bytes.length && buf.compare(bytes, 0, len, at, at + len) === 0;
const NAME = {
  inhabited: Buffer.from("InhabitedTime"),
  status: Buffer.from("Status"),
  statusLower: Buffer.from("status"),
  blockEntities: Buffer.from("block_entities"),
  structures: Buffer.from("structures"),
  starts: Buffer.from("starts"),
  references: Buffer.from("References"),
  id: Buffer.from("id"),
};
const FULL = ["minecraft:full", "full"];

/** The entries of a compound at `pos` (after its type and name), calling visit(nameAt, nameLen, type, valuePos) which returns the new position. */
function walkCompound(buf, pos, visit) {
  const end = buf.length;
  for (;;) {
    if (pos >= end) throw overrun();
    const type = buf[pos++];
    if (type === TAG.END) return pos;
    if (pos + 2 > end) throw overrun();
    const nameLen = buf.readUInt16BE(pos);
    const nameAt = pos + 2;
    pos = nameAt + nameLen;
    if (pos > end) throw overrun();
    pos = visit(nameAt, nameLen, type, pos);
  }
}

/** Entry count of a compound of compounds or long arrays: how many keys it has, without decoding them. */
function countEntries(buf, pos) {
  let n = 0;
  const after = walkCompound(buf, pos, (_a, _l, type, valuePos) => {
    n++;
    return skipAt(buf, valuePos, type);
  });
  return { n, after };
}

/**
 * InhabitedTime plus the signals of a 1.18+ chunk, in one pass that decodes only
 * what it needs: ids of block entities and the number of structure starts and
 * references. Names and everything else are skipped without decoding.
 *
 * @returns {{inhabited: number|undefined, flags: number, blockEntities: number}}
 */
function chunkSignals(buf) {
  if (buf.length < 3 || buf[0] !== TAG.COMPOUND) throw new NbtError("Chunk root is not a compound");
  let inhabited;
  let flags = 0;
  let blockEntities = 0;
  walkCompound(buf, 3 + buf.readUInt16BE(1), (nameAt, nameLen, type, pos) => {
    if (type === TAG.LONG && eq(buf, nameAt, nameLen, NAME.inhabited)) {
      if (pos + 8 > buf.length) throw overrun();
      inhabited = buf.readInt32BE(pos) * 4294967296 + buf.readUInt32BE(pos + 4);
      return pos + 8;
    }
    if (type === TAG.STRING && (eq(buf, nameAt, nameLen, NAME.status) || eq(buf, nameAt, nameLen, NAME.statusLower))) {
      const len = buf.readUInt16BE(pos);
      const value = buf.toString("utf8", pos + 2, pos + 2 + len);
      if (!FULL.includes(value)) flags |= SIGNAL.NOT_FULL;
      return pos + 2 + len;
    }
    if (type === TAG.LIST && eq(buf, nameAt, nameLen, NAME.blockEntities)) {
      const inner = buf[pos];
      const count = buf.readInt32BE(pos + 1);
      pos += 5;
      if (inner !== TAG.COMPOUND || count <= 0) return pos;
      for (let i = 0; i < count; i++) {
        blockEntities++;
        let kind = SIGNAL.OTHER_BLOCK_ENTITY;
        pos = walkCompound(buf, pos, (an, al, at, vp) => {
          if (at === TAG.STRING && eq(buf, an, al, NAME.id)) {
            const len = buf.readUInt16BE(vp);
            kind = blockEntityKind(buf.toString("utf8", vp + 2, vp + 2 + len));
            return vp + 2 + len;
          }
          return skipAt(buf, vp, at);
        });
        flags |= kind;
      }
      return pos;
    }
    if (type === TAG.COMPOUND && eq(buf, nameAt, nameLen, NAME.structures)) {
      return walkCompound(buf, pos, (an, al, at, vp) => {
        if (at === TAG.COMPOUND && eq(buf, an, al, NAME.starts)) {
          const { n, after } = countEntries(buf, vp);
          if (n > 0) flags |= SIGNAL.STRUCTURE_START;
          return after;
        }
        if (at === TAG.COMPOUND && eq(buf, an, al, NAME.references)) {
          const { n, after } = countEntries(buf, vp);
          if (n > 0) flags |= SIGNAL.STRUCTURE_REFERENCE;
          return after;
        }
        return skipAt(buf, vp, at);
      });
    }
    return skipAt(buf, pos, type);
  });
  return { inhabited, flags, blockEntities };
}

// ── Signals by search instead of by walk ──

/** A tag header as it sits in the file: type, name length, name. */
const header = (type, name) => Buffer.concat([Buffer.from([type, name.length >> 8, name.length & 255]), Buffer.from(name)]);
const FIND = {
  inhabited: header(TAG.LONG, "InhabitedTime"),
  status: header(TAG.STRING, "Status"),
  statusLower: header(TAG.STRING, "status"),
  blockEntities: header(TAG.LIST, "block_entities"),
  structures: header(TAG.COMPOUND, "structures"),
};

/** Block entity ids and their kinds, from the list whose payload starts at `pos`. Returns the flags and the count. */
function readBlockEntities(buf, pos) {
  const inner = buf[pos];
  const count = buf.readInt32BE(pos + 1);
  pos += 5;
  let flags = 0;
  if (inner !== TAG.COMPOUND || count <= 0) return { flags, count: 0 };
  for (let i = 0; i < count; i++) {
    let kind = SIGNAL.OTHER_BLOCK_ENTITY;
    pos = walkCompound(buf, pos, (an, al, at, vp) => {
      if (at === TAG.STRING && eq(buf, an, al, NAME.id)) {
        const len = buf.readUInt16BE(vp);
        kind = blockEntityKind(buf.toString("utf8", vp + 2, vp + 2 + len));
        return vp + 2 + len;
      }
      return skipAt(buf, vp, at);
    });
    flags |= kind;
  }
  return { flags, count };
}

/** Structure start and reference bits, from the compound whose payload starts at `pos`. */
function readStructures(buf, pos) {
  let flags = 0;
  walkCompound(buf, pos, (an, al, at, vp) => {
    if (at === TAG.COMPOUND && eq(buf, an, al, NAME.starts)) {
      const { n, after } = countEntries(buf, vp);
      if (n > 0) flags |= SIGNAL.STRUCTURE_START;
      return after;
    }
    if (at === TAG.COMPOUND && eq(buf, an, al, NAME.references)) {
      const { n, after } = countEntries(buf, vp);
      if (n > 0) flags |= SIGNAL.STRUCTURE_REFERENCE;
      return after;
    }
    return skipAt(buf, vp, at);
  });
  return flags;
}

/**
 * The same answer as chunkSignals, found by searching for the few tags it wants
 * instead of walking past the sections, which are most of the document and hold
 * nothing it needs. A tag header (type byte, name length, name) is long enough
 * that a false hit inside block data is not a practical concern, and each hit is
 * parsed from there, so a damaged document still throws.
 *
 * @returns {{inhabited: number|undefined, flags: number, blockEntities: number}}
 */
function chunkSignalsFast(buf) {
  if (buf.length < 3 || buf[0] !== TAG.COMPOUND) throw new NbtError("Chunk root is not a compound");
  let inhabited;
  let flags = 0;
  let blockEntities = 0;

  let at = buf.indexOf(FIND.inhabited);
  if (at >= 0) {
    const pos = at + FIND.inhabited.length;
    if (pos + 8 > buf.length) throw overrun();
    inhabited = buf.readInt32BE(pos) * 4294967296 + buf.readUInt32BE(pos + 4);
  }

  at = buf.indexOf(FIND.status);
  if (at < 0) at = buf.indexOf(FIND.statusLower);
  if (at >= 0) {
    const pos = at + FIND.status.length;
    if (pos + 2 > buf.length) throw overrun();
    const len = buf.readUInt16BE(pos);
    if (pos + 2 + len > buf.length) throw overrun();
    if (!FULL.includes(buf.toString("utf8", pos + 2, pos + 2 + len))) flags |= SIGNAL.NOT_FULL;
  }

  at = buf.indexOf(FIND.blockEntities);
  if (at >= 0) {
    const pos = at + FIND.blockEntities.length;
    if (pos + 5 > buf.length) throw overrun();
    const found = readBlockEntities(buf, pos);
    flags |= found.flags;
    blockEntities = found.count;
  }

  at = buf.indexOf(FIND.structures);
  if (at >= 0) flags |= readStructures(buf, at + FIND.structures.length);

  return { inhabited, flags, blockEntities };
}

// ── Terrain: what a top-down map needs ──

const TERRAIN = {
  yPos: header(TAG.INT, "yPos"),
  heightmaps: header(TAG.COMPOUND, "Heightmaps"),
  sections: header(TAG.LIST, "sections"),
};
const N = {
  Y: Buffer.from("Y"),
  blockStates: Buffer.from("block_states"),
  palette: Buffer.from("palette"),
  data: Buffer.from("data"),
  name: Buffer.from("Name"),
};

/**
 * The parts of a 1.18+ chunk a top-down map is drawn from, without decoding the rest.
 * Long arrays stay raw bytes (big endian, 8 per entry): a packed value can use all 64 bits,
 * which a JavaScript number cannot hold.
 *
 * @returns {{minSectionY: number, heightmaps: Record<string, Buffer>, sections: Map<number, {palette: string[], data: Buffer|null}>}}
 */
function chunkTerrain(buf) {
  if (buf.length < 3 || buf[0] !== TAG.COMPOUND) throw new NbtError("Chunk root is not a compound");
  const heightmaps = {};
  const sections = new Map();
  let minSectionY = -4;

  let at = buf.indexOf(TERRAIN.yPos);
  if (at >= 0) {
    const pos = at + TERRAIN.yPos.length;
    if (pos + 4 > buf.length) throw overrun();
    minSectionY = buf.readInt32BE(pos);
  }

  at = buf.indexOf(TERRAIN.heightmaps);
  if (at >= 0) {
    walkCompound(buf, at + TERRAIN.heightmaps.length, (an, al, atype, vp) => {
      if (atype === TAG.LONG_ARRAY) {
        const count = buf.readInt32BE(vp);
        if (count < 0 || vp + 4 + count * 8 > buf.length) throw overrun();
        heightmaps[buf.toString("utf8", an, an + al)] = buf.subarray(vp + 4, vp + 4 + count * 8);
      }
      return skipAt(buf, vp, atype);
    });
  }

  at = buf.indexOf(TERRAIN.sections);
  if (at >= 0) {
    let pos = at + TERRAIN.sections.length;
    if (pos + 5 > buf.length) throw overrun();
    const inner = buf[pos];
    const count = buf.readInt32BE(pos + 1);
    pos += 5;
    if (inner === TAG.COMPOUND) {
      for (let i = 0; i < count; i++) {
        let y;
        let palette = [];
        let data = null;
        pos = walkCompound(buf, pos, (an, al, atype, vp) => {
          if (atype === TAG.BYTE && eq(buf, an, al, N.Y)) {
            y = buf.readInt8(vp);
            return vp + 1;
          }
          if (atype === TAG.COMPOUND && eq(buf, an, al, N.blockStates)) {
            return walkCompound(buf, vp, (bn, bl, btype, bp) => {
              if (btype === TAG.LIST && eq(buf, bn, bl, N.palette)) {
                const kind = buf[bp];
                const entries = buf.readInt32BE(bp + 1);
                let p = bp + 5;
                if (kind !== TAG.COMPOUND || entries < 0) return skipAt(buf, bp, btype);
                for (let e = 0; e < entries; e++) {
                  let name = "minecraft:air";
                  p = walkCompound(buf, p, (cn, cl, ctype, cp) => {
                    if (ctype === TAG.STRING && eq(buf, cn, cl, N.name)) {
                      const len = buf.readUInt16BE(cp);
                      name = buf.toString("utf8", cp + 2, cp + 2 + len);
                      return cp + 2 + len;
                    }
                    return skipAt(buf, cp, ctype);
                  });
                  palette.push(name);
                }
                return p;
              }
              if (btype === TAG.LONG_ARRAY && eq(buf, bn, bl, N.data)) {
                const longs = buf.readInt32BE(bp);
                if (longs < 0 || bp + 4 + longs * 8 > buf.length) throw overrun();
                data = buf.subarray(bp + 4, bp + 4 + longs * 8);
                return bp + 4 + longs * 8;
              }
              return skipAt(buf, bp, btype);
            });
          }
          return skipAt(buf, vp, atype);
        });
        if (y !== undefined) sections.set(y, { palette, data });
      }
    }
  }
  return { minSectionY, heightmaps, sections };
}

/**
 * Entry `index` of a packed long array: `bits` bits each, as many whole entries per long as fit
 * (an entry never spans two longs, as since 1.16). `raw` holds the longs big endian.
 */
function unpackAt(raw, bits, index) {
  const per = Math.floor(64 / bits);
  const base = Math.floor(index / per) * 8;
  const offset = (index % per) * bits;
  if (base + 8 > raw.length) return 0;
  const hi = raw.readUInt32BE(base);
  const lo = raw.readUInt32BE(base + 4);
  const mask = (1 << bits) - 1;
  if (offset >= 32) return (hi >>> (offset - 32)) & mask;
  if (offset + bits <= 32) return (lo >>> offset) & mask;
  const fromLo = 32 - offset;
  return ((lo >>> offset) | ((hi & ((1 << (bits - fromLo)) - 1)) << fromLo)) & mask;
}

module.exports = { TAG, NbtError, parseNbt, chunkMeta, inhabitedTime, chunkSignals, chunkSignalsFast, chunkTerrain, unpackAt, SIGNAL, blockEntityKind };
