// Builds small but real worlds for the prune tests: NBT, Anvil region files,
// level.dat, player data and server.properties. Nothing here touches a real world.
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");

const SECTOR = 4096;

// ── NBT writer ──
const T = { BYTE: 1, SHORT: 2, INT: 3, LONG: 4, DOUBLE: 6, STRING: 8, LIST: 9, COMPOUND: 10, INT_ARRAY: 11, LONG_ARRAY: 12 };

const u8 = (n) => Buffer.from([n]);
const i16 = (n) => {
  const b = Buffer.alloc(2);
  b.writeInt16BE(n);
  return b;
};
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
const f64 = (n) => {
  const b = Buffer.alloc(8);
  b.writeDoubleBE(n);
  return b;
};
const str = (s) => {
  const body = Buffer.from(s, "utf8");
  return Buffer.concat([i16(body.length), body]);
};

/** A named tag: type byte, name, payload. */
const tag = (type, name, payload) => Buffer.concat([u8(type), str(name), payload]);
const long = (name, n) => tag(T.LONG, name, i64(n));
const int = (name, n) => tag(T.INT, name, i32(n));
const string = (name, s) => tag(T.STRING, name, str(s));
const compound = (name, ...children) => tag(T.COMPOUND, name, Buffer.concat([...children, u8(0)]));
const longArray = (name, values) => tag(T.LONG_ARRAY, name, Buffer.concat([i32(values.length), ...values.map(i64)]));
const doubleList = (name, values) => tag(T.LIST, name, Buffer.concat([u8(T.DOUBLE), i32(values.length), ...values.map(f64)]));
const compoundList = (name, items) =>
  tag(T.LIST, name, Buffer.concat([u8(T.COMPOUND), i32(items.length), ...items.map((c) => Buffer.concat([...c, u8(0)]))]));
/** The root compound of a document. */
const stringList = (name, values) => tag(T.LIST, name, Buffer.concat([u8(T.STRING), i32(values.length), ...values.map(str)]));
const root = (...children) => Buffer.concat([u8(T.COMPOUND), str(""), ...children, u8(0)]);

/** A 1.18+ chunk: flat root. `padding` is junk that has to be skipped to find the fields. */
function chunkModern({ x, z, inhabited, status = "minecraft:full", padding = 64, blockEntities = [], structureStarts = [], structureRefs = [] }) {
  const tail = [];
  if (blockEntities.length > 0) {
    tail.push(compoundList("block_entities", blockEntities.map((id) => [string("id", id), int("x", x * 16), int("y", 64), int("z", z * 16)])));
  }
  if (structureStarts.length > 0 || structureRefs.length > 0) {
    tail.push(
      compound(
        "structures",
        compound("starts", ...structureStarts.map((k) => compound(k, string("id", k)))),
        compound("References", ...structureRefs.map((k) => longArray(k, [1]))),
      ),
    );
  }
  return root(
    int("DataVersion", 3955),
    int("xPos", x),
    int("zPos", z),
    long("LastUpdate", 1000),
    long("InhabitedTime", inhabited),
    string("Status", status),
    longArray("Heightmaps", new Array(padding).fill(7)),
    compoundList("sections", [[int("Y", 0), string("note", "x")], [int("Y", 1)]]),
    ...tail,
  );
}

const byteTag = (name, n) => tag(T.BYTE, name, Buffer.from([n & 0xff]));
const longArrayBig = (name, values) =>
  tag(T.LONG_ARRAY, name, Buffer.concat([i32(values.length), ...values.map((v) => {
    const b = Buffer.alloc(8);
    b.writeBigInt64BE(BigInt.asIntN(64, v));
    return b;
  })]));

/** Pack `values` (each below 2^bits) the way the game does since 1.16: whole entries per long, none spanning two. */
function packLongs(values, bits) {
  const per = Math.floor(64 / bits);
  const out = [];
  for (let i = 0; i < values.length; i += per) {
    let word = 0n;
    for (let k = 0; k < per && i + k < values.length; k++) word |= BigInt(values[i + k]) << BigInt(k * bits);
    out.push(word);
  }
  return out;
}

/**
 * A 1.18+ chunk with real terrain: a height map and packed block palettes, from a function
 * `blockAt(x, y, z)` (chunk-local x and z, world y) that returns a block id or undefined for air.
 */
/**
 * The block palette of one section in the layout `style` names:
 *   "names"   {Name: id} compounds, as up to 26.2;
 *   "strings" plain ids, as 26.3 writes a palette without properties;
 *   "mixed"   26.3's list when some block has properties: {id, properties} for grass blocks
 *             (with snowy=false) and {"": id} for the rest.
 */
function palette(names, style) {
  if (style === "strings") return stringList("palette", names);
  if (style === "mixed") {
    return compoundList("palette", names.map((n) =>
      n === "minecraft:grass_block" ? [string("id", n), compound("properties", string("snowy", "false"))] : [string("", n)],
    ));
  }
  return compoundList("palette", names.map((n) => [string("Name", n)]));
}

function chunkTerrain({ x, z, minSectionY = -4, sectionCount = 24, blockAt, inhabited = 0, heightBits = 9, paletteStyle = "names" }) {
  const minY = minSectionY * 16;
  const heights = [];
  for (let zz = 0; zz < 16; zz++) {
    for (let xx = 0; xx < 16; xx++) {
      let top = minY - 1;
      for (let y = minY + sectionCount * 16 - 1; y >= minY; y--) {
        if (blockAt(xx, y, zz)) {
          top = y;
          break;
        }
      }
      heights.push(top + 1 - minY);
    }
  }
  const sections = [];
  for (let s = 0; s < sectionCount; s++) {
    const y0 = (minSectionY + s) * 16;
    const names = [];
    const indices = [];
    for (let yy = 0; yy < 16; yy++) {
      for (let zz = 0; zz < 16; zz++) {
        for (let xx = 0; xx < 16; xx++) {
          const name = blockAt(xx, y0 + yy, zz) ?? "minecraft:air";
          let index = names.indexOf(name);
          if (index < 0) index = names.push(name) - 1;
          indices.push(index);
        }
      }
    }
    const pal = palette(names, paletteStyle);
    const bits = Math.max(4, Math.ceil(Math.log2(Math.max(2, names.length))));
    const states = names.length === 1 ? compound("block_states", pal) : compound("block_states", pal, longArrayBig("data", packLongs(indices, bits)));
    sections.push([byteTag("Y", minSectionY + s), states]);
  }
  return root(
    int("DataVersion", 3955),
    int("xPos", x),
    int("zPos", z),
    int("yPos", minSectionY),
    long("LastUpdate", 1000),
    long("InhabitedTime", inhabited),
    string("Status", "minecraft:full"),
    compound("Heightmaps", longArrayBig("WORLD_SURFACE", packLongs(heights, heightBits))),
    compoundList("sections", sections),
  );
}

/** A pre-1.18 chunk: everything under Level. */
function chunkLegacy({ x, z, inhabited }) {
  return root(
    int("DataVersion", 2586),
    compound("Level", int("xPos", x), int("zPos", z), long("LastUpdate", 5), long("InhabitedTime", inhabited), string("Status", "full")),
  );
}

// ── Region writer ──
const compress = {
  zlib: (b) => ({ id: 2, data: zlib.deflateSync(b) }),
  gzip: (b) => ({ id: 1, data: zlib.gzipSync(b) }),
  none: (b) => ({ id: 3, data: b }),
  lz4: (b) => ({ id: 4, data: b }), // not real LZ4: the reader cannot decode it either way
  corrupt: () => ({ id: 2, data: Buffer.from("not zlib at all") }),
};

/**
 * Write r.X.Z.mca holding `chunks` ([{x, z, nbt, compression?}], absolute chunk
 * coordinates). Returns the sector layout per slot.
 */
function writeRegion(file, rx, rz, chunks) {
  const header = Buffer.alloc(2 * SECTOR);
  const parts = [];
  let next = 2;
  for (const c of chunks) {
    const slot = (c.x & 31) + (c.z & 31) * 32;
    const { id, data } = compress[c.compression ?? "zlib"](c.nbt);
    const body = Buffer.concat([i32(data.length + 1), u8(id), data]);
    const sectors = Math.ceil(body.length / SECTOR);
    const padded = Buffer.alloc(sectors * SECTOR);
    body.copy(padded);
    header.writeUInt32BE((next << 8) | sectors, slot * 4);
    header.writeUInt32BE(1_700_000_000 + slot, SECTOR + slot * 4);
    parts.push(padded);
    next += sectors;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.concat([header, ...parts]));
}

// ── A world on disk ──
function makeServer({ levelName = "world" } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-prune-"));
  fs.writeFileSync(path.join(dir, "server.properties"), `level-name=${levelName}\n`);
  const worldDir = path.join(dir, levelName);
  fs.mkdirSync(worldDir, { recursive: true });
  return {
    dir,
    worldDir,
    regionFile: (dimDir, folder, rx, rz) => path.join(dimDir ?? worldDir, folder, `r.${rx}.${rz}.mca`),
    cleanup: () => fs.rmSync(dir, { recursive: true, force: true }),
  };
}

function writeLevelDat(worldDir, spawnX, spawnZ) {
  const nbt = root(compound("Data", int("SpawnX", spawnX), int("SpawnY", 64), int("SpawnZ", spawnZ)));
  fs.writeFileSync(path.join(worldDir, "level.dat"), zlib.gzipSync(nbt));
}

const intArray = (name, values) => tag(T.INT_ARRAY, name, Buffer.concat([i32(values.length), ...values.map(i32)]));

/**
 * A player file; `folder` is "playerdata" (before 26.x) or "players/data" (26.x).
 * `spawn` adds the pre-1.21.5 respawn fields, `respawn` the compound since then,
 * and `corrupt` writes bytes that are not NBT.
 */
function writePlayer(worldDir, uuid, { dimension = "minecraft:overworld", x, z, folder = "playerdata", spawn = null, respawn = null, corrupt = false }) {
  const dir = path.join(worldDir, ...folder.split("/"));
  fs.mkdirSync(dir, { recursive: true });
  if (corrupt) {
    fs.writeFileSync(path.join(dir, `${uuid}.dat`), Buffer.from("not nbt at all"));
    return;
  }
  const extra = [];
  if (spawn) {
    extra.push(int("SpawnX", spawn.x), int("SpawnY", 64), int("SpawnZ", spawn.z));
    if (spawn.dimension) extra.push(string("SpawnDimension", spawn.dimension));
  }
  if (respawn) {
    extra.push(compound("respawn", intArray("pos", [respawn.x, 64, respawn.z]), string("dimension", respawn.dimension ?? "minecraft:overworld")));
  }
  const nbt = root(string("Dimension", dimension), doubleList("Pos", [x, 70, z]), ...extra);
  fs.writeFileSync(path.join(dir, `${uuid}.dat`), zlib.gzipSync(nbt));
}

/**
 * <dimDir>/data/chunks.dat with the given [x, z] chunk positions force-loaded:
 * `format` "forced" is the packed long array (`data.Forced`), "tickets" a list of
 * entries with a `chunk_pos` int pair. "corrupt" writes bytes that are not NBT.
 */
function writeForcedChunks(dimDir, positions, { format = "forced" } = {}) {
  const dir = path.join(dimDir, "data");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "chunks.dat");
  if (format === "corrupt") {
    fs.writeFileSync(file, Buffer.from("not nbt at all"));
    return;
  }
  let nbt;
  if (format === "tickets") {
    nbt = root(compound("data", compoundList("tickets", positions.map(([x, z]) => [intArray("chunk_pos", [x, z]), string("type", "minecraft:forced")]))));
  } else {
    const packed = positions.map(([x, z]) => BigInt.asIntN(64, BigInt.asUintN(32, BigInt(x)) | (BigInt.asUintN(32, BigInt(z)) << 32n)));
    nbt = root(compound("data", longArray("Forced", packed)));
  }
  fs.writeFileSync(file, zlib.gzipSync(nbt));
}

module.exports = {
  SECTOR,
  chunkModern,
  chunkTerrain,
  packLongs,
  chunkLegacy,
  writeRegion,
  makeServer,
  writeLevelDat,
  writePlayer,
  writeForcedChunks,
};
