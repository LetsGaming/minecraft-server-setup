const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");

const fx = require("./worldFixtures.cjs");
const tiles = require("../../src/scripts/world/lib/tiles.js");
const { colorOf } = require("../../src/scripts/world/lib/blockColors.js");
const { chunkTerrain, unpackAt } = require("../../src/scripts/world/lib/nbt.js");

const grass = [110, 170, 60];

/** Flat ground at y 64, a pond and a hill, so a tile has something to show. */
function ground(x, z) {
  return (bx, y, bz) => {
    const wx = x * 16 + bx;
    const wz = z * 16 + bz;
    const pond = wx >= 20 && wx < 28 && wz >= 20 && wz < 28;
    const hill = wx >= 40 && wx < 48 && wz >= 40 && wz < 48;
    const top = hill ? 70 : 64;
    if (y > top) return pond && y <= 64 ? "minecraft:water" : undefined;
    if (pond && y > 60) return y <= 64 ? "minecraft:water" : undefined;
    if (y === top) return pond ? "minecraft:sand" : "minecraft:grass_block";
    return "minecraft:stone";
  };
}

function withWorld(fn) {
  return () => {
    const s = fx.makeServer();
    const tilesDir = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-tiles-"));
    try {
      fx.writeLevelDat(s.worldDir, 0, 0);
      fn(s, tilesDir);
    } finally {
      s.cleanup();
      fs.rmSync(tilesDir, { recursive: true, force: true });
    }
  };
}

function writeGround(s, rx = 0, rz = 0) {
  const list = [];
  for (let cz = 0; cz < 4; cz++) {
    for (let cx = 0; cx < 4; cx++) {
      const x = rx * 32 + cx;
      const z = rz * 32 + cz;
      list.push({ x, z, nbt: fx.chunkTerrain({ x, z, sectionCount: 24, blockAt: ground(cx, cz) }) });
    }
  }
  fx.writeRegion(s.regionFile(null, "region", rx, rz), rx, rz, list);
}

/** The RGBA pixels of a PNG this module wrote (RGBA, 8 bit, no filtering). */
function decodePng(png) {
  assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  let pos = 8;
  let width = 0;
  let height = 0;
  const idat = [];
  while (pos < png.length) {
    const len = png.readUInt32BE(pos);
    const type = png.toString("ascii", pos + 4, pos + 8);
    const data = png.subarray(pos + 8, pos + 8 + len);
    assert.equal(png.readUInt32BE(pos + 8 + len), zlib.crc32(png.subarray(pos + 4, pos + 8 + len)) >>> 0, `crc of ${type}`);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.deepEqual([data[8], data[9], data[12]], [8, 6, 0]);
    } else if (type === "IDAT") idat.push(data);
    pos += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    assert.equal(raw[y * (width * 4 + 1)], 0);
    raw.copy(out, y * width * 4, y * (width * 4 + 1) + 1, (y + 1) * (width * 4 + 1));
  }
  return { width, height, rgba: out };
}

const px = (rgba, x, z) => [...rgba.subarray((z * 512 + x) * 4, (z * 512 + x) * 4 + 4)];

// ── packed data ──

test("unpackAt reads back what the game's packing wrote, at every width, across the 32 bit boundary", () => {
  let seed = 5;
  const rand = (n) => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n);
  for (const bits of [4, 5, 6, 7, 8, 9, 10, 11, 12]) {
    const values = Array.from({ length: 700 }, () => rand(1 << bits));
    const raw = Buffer.alloc(Math.ceil(values.length / Math.floor(64 / bits)) * 8);
    fx.packLongs(values, bits).forEach((w, i) => raw.writeBigUInt64BE(BigInt.asUintN(64, w), i * 8));
    for (let i = 0; i < values.length; i++) assert.equal(unpackAt(raw, bits, i), values[i], `bits ${bits} index ${i}`);
  }
});

test("chunkTerrain reads the height map, the section palettes and their packed data", () => {
  const t = chunkTerrain(fx.chunkTerrain({ x: 3, z: -2, blockAt: ground(3, 2) }));
  assert.equal(t.minSectionY, -4);
  assert.equal(t.sections.size, 24);
  assert.deepEqual([...t.sections.get(4).palette].sort(), ["minecraft:air", "minecraft:grass_block"].sort());
  assert.equal(unpackAt(t.heightmaps.WORLD_SURFACE, 9, 0), 64 + 1 + 64);
  assert.equal(t.sections.get(-4).palette.length, 1, "bedrock-level section of one block has no data");
  assert.equal(t.sections.get(-4).data, null);
});

/** A packed height map of 256 entries, as the game writes it, in the raw big-endian form the reader gets. */
function packedHeights(values, bits) {
  const longs = fx.packLongs(values, bits);
  const raw = Buffer.alloc(longs.length * 8);
  longs.forEach((l, i) => raw.writeBigUInt64BE(l, i * 8));
  return raw;
}

test("the height map entry width follows from its length, and from its padding where the length allows two", () => {
  const heights = (top) => Array.from({ length: 256 }, (_, i) => top - (i % 7));
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(129), 9)), 9);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(200), 8)), 8);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(500), 10)), 10);
  // 11 and 12 bits both make 52 longs; 13 to 16 bits all make 64.
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(1500), 11)), 11);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(2100), 12)), 12);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(2100), 13)), 13);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(9000), 14)), 14);
  // With the world's height the length's choices are settled by it, low terrain or not.
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(100), 12), 2096), 12);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(100), 11), 1024), 11);
  assert.equal(tiles.bitsOfHeightmap(packedHeights(heights(100), 9), 384), 9);
  assert.equal(tiles.bitsForPalette(2), 4);
  assert.equal(tiles.bitsForPalette(17), 5);
  assert.equal(tiles.bitsForPalette(513), 10);
});

// ── colours ──

test("block colours: the table, shapes of a material, families, unknown and modded blocks, and air", () => {
  assert.deepEqual(colorOf("minecraft:grass_block"), { rgb: grass, known: true });
  assert.deepEqual(colorOf("minecraft:oak_stairs").rgb, colorOf("minecraft:oak_planks").rgb);
  assert.deepEqual(colorOf("minecraft:stone_brick_slab").rgb, colorOf("minecraft:stone").rgb);
  assert.deepEqual(colorOf("minecraft:red_concrete").rgb, [160, 39, 34]);
  assert.ok(colorOf("minecraft:birch_leaves").known);
  assert.deepEqual(colorOf("minecraft:deepslate_iron_ore").rgb, colorOf("minecraft:deepslate").rgb);
  assert.deepEqual(colorOf("somemod:strange_block"), { rgb: [128, 128, 128], known: false });
  assert.equal(colorOf("minecraft:air"), null);
  assert.equal(colorOf("minecraft:cave_air"), null);
  assert.equal(colorOf("minecraft:light"), null);
  assert.deepEqual(colorOf("minecraft:totally_new_block"), { rgb: [128, 128, 128], known: false });
});

// ── tiles ──

test("a region is drawn from above: ground, sand and water by their own colours, empty chunks left clear", withWorld((s, dir) => {
  writeGround(s);
  const tile = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir });
  assert.equal(tile.cached, false);
  assert.equal(tile.chunks, 16);
  const { width, height, rgba } = decodePng(fs.readFileSync(tile.file));
  assert.deepEqual([width, height], [512, 512]);
  assert.deepEqual(px(rgba, 5, 5).slice(0, 3), grass.map((c) => c), "plain grass (flat ground has no relief)");
  assert.equal(px(rgba, 5, 5)[3], 255);
  const water = px(rgba, 22, 22);
  assert.ok(water[2] > water[0] && water[2] > water[1], "water is blue");
  assert.equal(px(rgba, 300, 300)[3], 0, "a chunk the region does not have stays transparent");
}));

test("deeper water is darker, and a hill shows relief against the ground north of it", withWorld((s, dir) => {
  const list = [];
  for (let cz = 0; cz < 4; cz++) {
    for (let cx = 0; cx < 4; cx++) {
      const x = cx;
      const z = cz;
      list.push({
        x,
        z,
        nbt: fx.chunkTerrain({
          x,
          z,
          blockAt: (bx, y, bz) => {
            const wx = x * 16 + bx;
            const wz = z * 16 + bz;
            if (y > 66) return undefined;
            if (wx < 8) return y <= 50 ? "minecraft:stone" : y <= 64 ? "minecraft:water" : undefined; // deep
            if (wx < 16) return y <= 60 ? "minecraft:stone" : y <= 64 ? "minecraft:water" : undefined; // shallow
            if (wz >= 40 && wz < 48 && wx >= 30 && wx < 40) return y <= 66 ? "minecraft:stone" : undefined; // hill
            return y <= 64 ? "minecraft:stone" : undefined;
          },
        }),
      });
    }
  }
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, list);
  const { rgba } = decodePng(fs.readFileSync(tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir }).file));
  const deep = px(rgba, 3, 30);
  const shallow = px(rgba, 12, 30);
  assert.ok(deep[2] < shallow[2], "deep water is darker than shallow");
  const flat = px(rgba, 25, 30);
  const hillFront = px(rgba, 34, 40); // first row of the hill: higher than the ground north of it
  assert.ok(hillFront[0] > flat[0], "the step up is lit");
  const behind = px(rgba, 34, 48); // first row after the hill: lower than the hill north of it
  assert.ok(behind[0] < flat[0], "the step down is darker");
}));

test("a world taller than 2048 blocks (12 bit height map) is drawn whole, not in diagonal stripes", withWorld((s, dir) => {
  const flat = (bx, y) => (y < 64 ? "minecraft:stone" : y === 64 ? "minecraft:grass_block" : undefined);
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [
    { x: 0, z: 0, nbt: fx.chunkTerrain({ x: 0, z: 0, blockAt: flat, heightBits: 12 }) },
  ]);
  const { rgba } = decodePng(fs.readFileSync(tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir }).file));
  for (let z = 0; z < 16; z++) {
    for (let x = 0; x < 16; x++) assert.deepEqual(px(rgba, x, z), [...grass, 255], `column ${x}, ${z}`);
  }
}));

test("a 2096 block tall world with low terrain is drawn whole: the height decides 11 or 12 bits, not the padding", withWorld((s, dir) => {
  // As on a real modded 26.3 server: 131 sections (Y -4..126), 12 bit height maps, ground at
  // sea level, so the top bits of every long happen to be zero and look like 11 bit padding.
  // Top block at y 62: a height of 127 above the bottom, as in the chunk the server reported.
  const sea = (bx, y) => (y < 62 ? "minecraft:stone" : y === 62 ? "minecraft:grass_block" : undefined);
  const nbt = fx.chunkTerrain({ x: 0, z: 0, sectionCount: 131, blockAt: sea, heightBits: 12 });
  const terrain = chunkTerrain(nbt);
  assert.equal(tiles.heightOf(terrain), 2096);
  assert.equal(tiles.bitsOfHeightmap(terrain.heightmaps.WORLD_SURFACE), 11, "the padding alone guesses wrong here");
  assert.equal(tiles.bitsOfHeightmap(terrain.heightmaps.WORLD_SURFACE, 2096), 12, "the height gets it right");
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [{ x: 0, z: 0, nbt }]);
  const { rgba } = decodePng(fs.readFileSync(tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir }).file));
  for (let z = 0; z < 16; z++) {
    for (let x = 0; x < 16; x++) assert.deepEqual(px(rgba, x, z), [...grass, 255], `column ${x}, ${z}`);
  }
}));

test("26.3 block palettes are read: plain ids, and mixed {id, properties} / {\"\": id} entries", () => {
  const ground = (bx, y) => (y < 63 ? "minecraft:stone" : y === 63 ? "minecraft:grass_block" : undefined);
  for (const paletteStyle of ["names", "strings", "mixed"]) {
    const t = chunkTerrain(fx.chunkTerrain({ x: 0, z: 0, blockAt: ground, paletteStyle }));
    // Section 3 is y 48..63: stone with the grass layer on top; section 4 above it is air.
    assert.deepEqual([...t.sections.get(3).palette].sort(), ["minecraft:grass_block", "minecraft:stone"], paletteStyle);
    assert.deepEqual(t.sections.get(4).palette, ["minecraft:air"], paletteStyle);
    assert.deepEqual(t.sections.get(0).palette, ["minecraft:stone"], `${paletteStyle}: a one-block section`);
    assert.equal(tiles.heightOf(t), 384, paletteStyle);
  }
});

test("a 26.3 chunk with the new palettes is drawn like an older one", withWorld((s, dir) => {
  const list = ["names", "strings", "mixed"].map((paletteStyle, i) => ({
    x: i,
    z: 0,
    nbt: fx.chunkTerrain({ x: i, z: 0, paletteStyle, blockAt: (bx, y) => (y < 63 ? "minecraft:stone" : y === 63 ? "minecraft:grass_block" : undefined) }),
  }));
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, list);
  const { rgba } = decodePng(fs.readFileSync(tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir }).file));
  for (let i = 0; i < 3; i++) assert.deepEqual(px(rgba, i * 16 + 5, 5), [...grass, 255], `chunk ${i}`);
}));

test("chunks without terrain data (older layout) leave their place clear instead of failing", withWorld((s, dir) => {
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, [
    { x: 0, z: 0, nbt: fx.chunkModern({ x: 0, z: 0, inhabited: 0 }) },
    { x: 1, z: 0, nbt: fx.chunkLegacy({ x: 1, z: 0, inhabited: 0 }) },
    { x: 2, z: 0, nbt: fx.chunkTerrain({ x: 2, z: 0, blockAt: ground(2, 0) }), compression: "corrupt" },
    { x: 3, z: 0, nbt: fx.chunkTerrain({ x: 3, z: 0, blockAt: ground(3, 0) }) },
  ]);
  const tile = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir });
  assert.equal(tile.chunks, 1);
  const { rgba } = decodePng(fs.readFileSync(tile.file));
  assert.equal(px(rgba, 5, 5)[3], 0);
  assert.equal(px(rgba, 3 * 16 + 5, 5)[3], 255);
}));

test("a second request is served from the cache, and an edited region gets a new tile and loses the old one", withWorld((s, dir) => {
  writeGround(s);
  const first = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir });
  const again = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir });
  assert.equal(again.cached, true);
  assert.equal(again.file, first.file);

  const list = [{ x: 0, z: 0, nbt: fx.chunkTerrain({ x: 0, z: 0, blockAt: (_x, y) => (y <= 70 ? "minecraft:sand" : undefined) }) }];
  fx.writeRegion(s.regionFile(null, "region", 0, 0), 0, 0, list);
  const edited = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir });
  assert.equal(edited.cached, false);
  assert.notEqual(edited.file, first.file);
  assert.equal(fs.existsSync(first.file), false, "the stale tile is gone");
  assert.deepEqual(fs.readdirSync(path.join(dir, "overworld")), [path.basename(edited.file)]);
  assert.match(edited.relative, /^overworld\/r\.0\.0\.[0-9a-f]{16}\.png$/);
}));

test("an unknown dimension or a missing region gives nothing", withWorld((s, dir) => {
  writeGround(s);
  assert.equal(tiles.tileFor({ serverPath: s.dir, dimension: "the_nether", rx: 0, rz: 0, tilesDir: dir }), null);
  assert.equal(tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 5, rz: 5, tilesDir: dir }), null);
}));

test("tiles are trimmed oldest first once the folder outgrows its limit", withWorld((s, dir) => {
  for (const [rx, rz] of [[0, 0], [1, 0], [0, 1]]) writeGround(s, rx, rz);
  const a = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 0, tilesDir: dir });
  fs.utimesSync(a.file, new Date(2020, 0, 1), new Date(2020, 0, 1));
  const b = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 1, rz: 0, tilesDir: dir });
  fs.utimesSync(b.file, new Date(2021, 0, 1), new Date(2021, 0, 1));
  const limit = a.bytes + b.bytes + 10;
  const c = tiles.tileFor({ serverPath: s.dir, dimension: "overworld", rx: 0, rz: 1, tilesDir: dir, maxBytes: limit });
  assert.equal(fs.existsSync(a.file), false, "the oldest went");
  assert.equal(fs.existsSync(c.file), true, "the new one stays");
}));
