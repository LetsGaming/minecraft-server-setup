"use strict";

/**
 * Terrain tiles for the prune map: one PNG per region, seen from above, one pixel
 * per block (512 x 512). Drawn only when someone looks at the region, cached on disk
 * under the region file's fingerprint (so a changed region can never show an old
 * picture), and trimmed to a size limit by age. It is a picture to orient by, not a
 * renderer: no biome tint, no shadows beyond a hint of relief.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const cache = require("./cache");
const { colorOf } = require("./blockColors");
const { chunkTerrain, unpackAt } = require("./nbt");
const region = require("./region");
const world = require("./world");

const SIZE = 512;
/**
 * Bumped when the drawing changes, so tiles drawn by an older version are drawn again instead of
 * being served from the cache until their region changes. 2: 12 bit height maps (worlds over
 * 2048 tall) were read as 11 bit and drawn in diagonal stripes. 3: the same maps were still read
 * as 11 bit where all the terrain is low, and those chunks were left empty. 4: the block palettes
 * 26.3 writes (plain ids, or {id, properties} and {"": id}) were read as empty, so every section
 * saved by 26.3 looked like air.
 */
const RENDER_VERSION = 4;
/** Tiles are kept up to this many bytes; the oldest go first. */
const DEFAULT_MAX_BYTES = 500 * 1024 * 1024;

const WATER = new Set(["water", "bubble_column", "kelp", "kelp_plant", "seagrass", "tall_seagrass"]);

function bitsForPalette(size) {
  return Math.max(4, Math.ceil(Math.log2(Math.max(2, size))));
}

/** The block name at (x, y, z) (section-relative y), or air for a section the chunk lacks. */
function blockName(section, x, y, z) {
  if (!section) return "minecraft:air";
  const { palette, data } = section;
  if (palette.length === 0) return "minecraft:air";
  if (!data || palette.length === 1) return palette[0];
  const index = unpackAt(data, bitsForPalette(palette.length), (y << 8) | (z << 4) | x);
  return palette[index] ?? palette[0];
}

/**
 * Paint one chunk into the region image. \`heights\` records each column's surface height for
 * the relief pass, and \`water\` which columns are water so they stay flat.
 */
function paintChunk(terrain, cx, cz, image, heights, water) {
  const heightmap = terrain.heightmaps.WORLD_SURFACE ?? terrain.heightmaps.MOTION_BLOCKING;
  if (!heightmap) return false;
  const minY = terrain.minSectionY * 16;
  // 9 bits covers 384 blocks; taller worlds (mods, datapacks) use wider entries.
  const bits = bitsOfHeightmap(heightmap, heightOf(terrain));
  let painted = false;
  for (let z = 0; z < 16; z++) {
    for (let x = 0; x < 16; x++) {
      let y = minY + unpackAt(heightmap, bits, z * 16 + x) - 1;
      let hit = null;
      let waterDepth = 0;
      let isWater = false;
      for (let step = 0; step < 48 && y >= minY; step++, y--) {
        const name = blockName(terrain.sections.get(y >> 4), x, y & 15, z);
        const base = name.startsWith("minecraft:") ? name.slice(10) : name;
        if (WATER.has(base)) {
          isWater = true;
          waterDepth++;
          continue;
        }
        const colour = colorOf(name);
        if (colour) {
          hit = colour.rgb;
          break;
        }
      }
      let rgb;
      if (isWater) {
        // Deeper water is darker; the bottom is not shown.
        const shade = Math.max(0.45, 1 - waterDepth * 0.06);
        rgb = [Math.round(52 * shade), Math.round(90 * shade), Math.round(200 * shade)];
      } else if (hit) {
        rgb = hit;
      } else {
        continue;
      }
      const px = (cx & 31) * 16 + x;
      const pz = (cz & 31) * 16 + z;
      const at = pz * SIZE + px;
      image[at * 4] = rgb[0];
      image[at * 4 + 1] = rgb[1];
      image[at * 4 + 2] = rgb[2];
      image[at * 4 + 3] = 255;
      heights[at] = y;
      water[at] = isWater ? 1 : 0;
      painted = true;
    }
  }
  return painted;
}

/**
 * The entry width of a packed height map (9 bits for a 384 tall world, and so on). The game
 * picks it from the world's height: enough bits for every height from 0 to the top. The number
 * of longs alone is ambiguous: 11 and 12 bits both fit 5 entries in a long (52 longs), 13 to 16
 * bits fit 4 (64 longs). So when the chunk tells the world's height (`heightBlocks`, from its
 * sections), that decides between the widths the length allows. Without it, the narrowest width
 * whose unused top bits are zero in every long is taken; that guess fails where all the terrain
 * is low (a 12 bit map of a field at sea level has those bits zero too), which is why the height
 * comes first.
 */
function bitsOfHeightmap(raw, heightBlocks) {
  const longs = raw.length / 8;
  const fits = [];
  for (let bits = 1; bits <= 16; bits++) {
    if (Math.ceil(256 / Math.floor(64 / bits)) === longs) fits.push(bits);
  }
  if (fits.length === 0) return 9;
  if (heightBlocks > 0) {
    const needed = Math.ceil(Math.log2(heightBlocks + 1));
    if (fits.includes(needed)) return needed;
  }
  for (const bits of fits) {
    if (paddingIsZero(raw, longs, Math.floor(64 / bits) * bits)) return bits;
  }
  return fits[0];
}

/**
 * The world's height in blocks as one chunk shows it: from its lowest section (yPos) to the top
 * of its highest section with blocks. Sections that only carry light (one above the top, in some
 * versions) have no block palette and are not counted.
 */
function heightOf(terrain) {
  let top = null;
  for (const [y, section] of terrain.sections) {
    if (section.palette.length > 0 && (top === null || y > top)) top = y;
  }
  return top === null ? 0 : (top - terrain.minSectionY + 1) * 16;
}

/** Whether bits from \`used\` up are zero in every long of \`raw\` (big endian). */
function paddingIsZero(raw, longs, used) {
  for (let i = 0; i < longs; i++) {
    if (raw.readBigUInt64BE(i * 8) >> BigInt(used) !== 0n) return false;
  }
  return true;
}

/** Light relief: a column higher than its northern neighbour is brighter, lower is darker. */
function relief(image, heights, water) {
  for (let z = 1; z < SIZE; z++) {
    for (let x = 0; x < SIZE; x++) {
      const at = z * SIZE + x;
      const north = at - SIZE;
      if (image[at * 4 + 3] === 0 || image[north * 4 + 3] === 0 || water[at]) continue;
      const diff = Math.max(-4, Math.min(4, heights[at] - heights[north]));
      if (diff === 0) continue;
      const factor = 1 + diff * 0.05;
      for (let c = 0; c < 3; c++) image[at * 4 + c] = Math.max(0, Math.min(255, Math.round(image[at * 4 + c] * factor)));
    }
  }
}

/**
 * Draw a region file. Chunks that cannot be read, or that predate the layout this reads,
 * are left transparent: the map then shows the plain class colour there.
 *
 * @returns {{rgba: Buffer, chunks: number}}
 */
function renderRegion(file, rx, rz) {
  const buf = fs.readFileSync(file);
  const header = region.readHeader(buf);
  const image = Buffer.alloc(SIZE * SIZE * 4);
  const heights = new Int16Array(SIZE * SIZE);
  const water = new Uint8Array(SIZE * SIZE);
  let chunks = 0;
  if (header) {
    const dir = path.dirname(file);
    for (const slot of region.occupiedSlots(header)) {
      const res = region.readChunk(buf, header, slot, dir, rx, rz);
      if (!res.ok) continue;
      let terrain;
      try {
        terrain = chunkTerrain(res.data);
      } catch {
        continue;
      }
      if (paintChunk(terrain, region.slotX(slot), region.slotZ(slot), image, heights, water)) chunks++;
    }
  }
  relief(image, heights, water);
  return { rgba: image, chunks };
}

// ── PNG ──

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  if (typeof zlib.crc32 === "function") return zlib.crc32(buf) >>> 0;
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

/** An RGBA image as a PNG (8 bits per channel, no interlace, no filtering). */
function encodePng(rgba, width, height) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const rows = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    rows[y * (width * 4 + 1)] = 0;
    rgba.copy(rows, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(rows, { level: 6 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ── Cache on disk ──

const tileName = (rx, rz, fp) => `r.${rx}.${rz}.${fp}.png`;

/** Delete the oldest tiles until the folder is under \`maxBytes\` (to 90 % of it, so it does not run every time). */
function trim(root, maxBytes) {
  const files = [];
  let total = 0;
  for (const dim of safeReaddir(root)) {
    for (const name of safeReaddir(path.join(root, dim))) {
      const full = path.join(root, dim, name);
      try {
        const st = fs.statSync(full);
        files.push({ full, size: st.size, mtime: st.mtimeMs });
        total += st.size;
      } catch {
        /* gone already */
      }
    }
  }
  if (total <= maxBytes) return 0;
  files.sort((a, b) => a.mtime - b.mtime);
  let removed = 0;
  for (const f of files) {
    if (total <= maxBytes * 0.9) break;
    fs.rmSync(f.full, { force: true });
    total -= f.size;
    removed++;
  }
  return removed;
}

function safeReaddir(dir) {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

/**
 * The tile of one region, drawn now or read from the cache. The file name carries the region
 * file's fingerprint, so an edited region gets a new tile and the old one is removed.
 *
 * @returns {{file: string, relative: string, cached: boolean, chunks: number, bytes: number} | null}
 *   null when the dimension or the region does not exist.
 */
function tileFor({ serverPath, dimension, rx, rz, tilesDir, maxBytes = DEFAULT_MAX_BYTES }) {
  const dim = world.discoverDimensions(world.worldDirOf(serverPath)).find((d) => d.id === dimension);
  if (!dim) return null;
  const file = path.join(dim.dir, "region", region.regionName(rx, rz));
  const fp = cache.fingerprint(file);
  if (!fp) return null;
  // Same shape as before (16 hex digits, which the wrapper checks), but new for each renderer version.
  const hex = crypto.createHash("sha256").update(fp).update(`tiles-v${RENDER_VERSION}`).digest("hex").slice(0, 16);
  const dir = path.join(tilesDir, dimension);
  const target = path.join(dir, tileName(rx, rz, hex));
  const relative = path.join(dimension, tileName(rx, rz, hex)).split(path.sep).join("/");

  if (fs.existsSync(target)) {
    const now = new Date();
    try {
      fs.utimesSync(target, now, now); // used just now: the last to be trimmed
    } catch {
      /* read-only cache: still usable */
    }
    return { file: target, relative, cached: true, chunks: 0, bytes: fs.statSync(target).size };
  }

  const { rgba, chunks } = renderRegion(file, rx, rz);
  const png = encodePng(rgba, SIZE, SIZE);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const old of safeReaddir(dir)) {
    if (old.startsWith(`r.${rx}.${rz}.`) && old !== path.basename(target)) fs.rmSync(path.join(dir, old), { force: true });
  }
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, png, { mode: 0o600 });
  fs.renameSync(tmp, target);
  trim(tilesDir, maxBytes);
  return { file: target, relative, cached: false, chunks, bytes: png.length };
}

module.exports = { SIZE, DEFAULT_MAX_BYTES, tileFor, renderRegion, encodePng, trim, bitsOfHeightmap, heightOf, bitsForPalette };
