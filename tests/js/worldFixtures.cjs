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

function writePlayer(worldDir, uuid, { dimension = "minecraft:overworld", x, z }) {
  fs.mkdirSync(path.join(worldDir, "playerdata"), { recursive: true });
  const nbt = root(string("Dimension", dimension), doubleList("Pos", [x, 70, z]));
  fs.writeFileSync(path.join(worldDir, "playerdata", `${uuid}.dat`), zlib.gzipSync(nbt));
}

module.exports = {
  SECTOR,
  chunkModern,
  chunkLegacy,
  writeRegion,
  makeServer,
  writeLevelDat,
  writePlayer,
};
