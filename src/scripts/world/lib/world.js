"use strict";

/**
 * Where a world's dimensions are and what must never be pruned: the spawn and
 * the places players were last seen.
 */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { parseNbt } = require("./nbt");

/** Folders that hold a dimension's chunks next to each other. */
const CHUNK_FOLDERS = ["region", "entities", "poi"];

const DIMENSION_IDS = {
  OVERWORLD: "overworld",
  NETHER: "the_nether",
  END: "the_end",
};

/**
 * A dimension id in one spelling, whichever file it came from: player data
 * writes "minecraft:the_nether" where the folder scan finds "the_nether".
 */
function normalizeDimensionId(id) {
  return typeof id === "string" ? id.replace(/^minecraft:/, "") : id;
}

function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/**
 * The world folder for a server: `level-name` from server.properties (default
 * "world"). The name is a folder name, never a path.
 */
function worldDirOf(serverPath) {
  let levelName = "world";
  try {
    const props = fs.readFileSync(path.join(serverPath, "server.properties"), "utf8");
    const m = /^level-name=(.*)$/m.exec(props);
    if (m && m[1].trim()) levelName = m[1].trim();
  } catch {
    /* default */
  }
  if (/[\\/]/.test(levelName) || levelName === "." || levelName === "..") {
    throw new Error("level-name is not a plain folder name");
  }
  return path.join(serverPath, levelName);
}

/**
 * Dimensions found on disk. Up to 26.x the overworld sits at the world root and the Nether and
 * the End in DIM-1 and DIM1; from 26.x on all three are under dimensions/minecraft/<name>, next
 * to datapack dimensions (dimensions/<ns>/<name>). The three vanilla ones keep the ids
 * "overworld", "the_nether" and "the_end" in either layout: spawn protection, player positions
 * and saved zones are matched by those ids. Where a world has both layouts, the newer one is
 * what the server uses. Discovered, not assumed: a folder counts only when it holds a region
 * folder.
 *
 * @returns {Array<{id: string, dir: string}>}
 */
function discoverDimensions(worldDir) {
  const found = [];
  const add = (id, dir) => {
    if (found.some((d) => d.id === id)) return;
    if (isDir(path.join(dir, "region"))) found.push({ id, dir });
  };
  const custom = path.join(worldDir, "dimensions");
  for (const [id, name] of VANILLA_FOLDERS) add(id, path.join(custom, "minecraft", name));
  add(DIMENSION_IDS.OVERWORLD, worldDir);
  add(DIMENSION_IDS.NETHER, path.join(worldDir, "DIM-1"));
  add(DIMENSION_IDS.END, path.join(worldDir, "DIM1"));

  if (isDir(custom)) {
    for (const ns of safeReaddir(custom)) {
      const nsDir = path.join(custom, ns);
      if (!isDir(nsDir)) continue;
      for (const name of safeReaddir(nsDir)) {
        if (ns === "minecraft" && VANILLA_FOLDERS.some(([, folder]) => folder === name)) continue;
        add(normalizeDimensionId(`${ns}:${name}`), path.join(nsDir, name));
      }
    }
  }
  return found;
}

/** The vanilla dimensions' folders under dimensions/minecraft/ (26.x and later). */
const VANILLA_FOLDERS = [
  [DIMENSION_IDS.OVERWORLD, "overworld"],
  [DIMENSION_IDS.NETHER, "the_nether"],
  [DIMENSION_IDS.END, "the_end"],
];

function safeReaddir(dir) {
  try {
    return fs.readdirSync(dir).sort();
  } catch {
    return [];
  }
}

function readNbtFile(file) {
  const raw = fs.readFileSync(file);
  // level.dat and playerdata are gzip; a few tools leave them plain.
  const buf = raw[0] === 0x1f && raw[1] === 0x8b ? zlib.gunzipSync(raw) : raw;
  return parseNbt(buf);
}

/** Dimension names in player data: a string since 1.16, a number before. */
function dimensionIdOf(value) {
  if (value === 0 || value === "minecraft:overworld") return DIMENSION_IDS.OVERWORLD;
  if (value === -1 || value === "minecraft:the_nether") return DIMENSION_IDS.NETHER;
  if (value === 1 || value === "minecraft:the_end") return DIMENSION_IDS.END;
  if (typeof value === "string") return normalizeDimensionId(value);
  return DIMENSION_IDS.OVERWORLD;
}

/**
 * The world spawn in block coordinates, or null when level.dat does not say.
 * Older worlds keep SpawnX/SpawnZ; newer ones may nest it, so both are tried.
 */
function readSpawn(worldDir) {
  try {
    const data = readNbtFile(path.join(worldDir, "level.dat")).Data ?? {};
    if (typeof data.SpawnX === "number" && typeof data.SpawnZ === "number") {
      return { x: data.SpawnX, z: data.SpawnZ };
    }
    const pos = data.spawn?.pos;
    if (Array.isArray(pos) && pos.length >= 3) return { x: pos[0], z: pos[2] };
  } catch {
    /* fall through */
  }
  return null;
}

/**
 * Where each known player last was and where they respawn:
 * `[{dimension, x, z, kind: "player" | "respawn"}]` in block coordinates, from
 * players/data/*.dat (26.x) or playerdata/*.dat. A file that cannot be read adds
 * nothing, so that player is not protected by position; its name goes to
 * `issues.unreadablePlayers` when the caller passes an `issues` object.
 */
function readPlayerPositions(worldDir, issues = null) {
  const out = [];
  const seen = new Set();
  // 26.x keeps player files in players/data/, older worlds in playerdata/. A world converted
  // to 26.x can hold both; the newer file of a player is the one the server uses.
  for (const dir of [path.join(worldDir, "players", "data"), path.join(worldDir, "playerdata")]) {
    for (const name of safeReaddir(dir)) {
      if (!name.endsWith(".dat") || seen.has(name)) continue;
      seen.add(name);
      if (!readPlayer(path.join(dir, name), out) && issues) {
        (issues.unreadablePlayers ??= []).push(name);
      }
    }
  }
  return out;
}

/** Add where one player file says its player was and respawns. False when the file cannot be read. */
function readPlayer(file, out) {
  let nbt;
  try {
    nbt = readNbtFile(file);
  } catch {
    return false;
  }
  const pos = nbt.Pos;
  if (Array.isArray(pos) && pos.length >= 3) {
    out.push({ dimension: dimensionIdOf(nbt.Dimension), x: pos[0], z: pos[2], kind: "player" });
  }
  // Before 1.21.5 the respawn point is SpawnX/SpawnZ/SpawnDimension; since then a "respawn" compound.
  if (typeof nbt.SpawnX === "number" && typeof nbt.SpawnZ === "number") {
    out.push({ dimension: dimensionIdOf(nbt.SpawnDimension), x: nbt.SpawnX, z: nbt.SpawnZ, kind: "respawn" });
  }
  const respawn = nbt.respawn;
  if (respawn && typeof respawn === "object" && Array.isArray(respawn.pos) && respawn.pos.length >= 3) {
    out.push({ dimension: dimensionIdOf(respawn.dimension), x: respawn.pos[0], z: respawn.pos[2], kind: "respawn" });
  }
  return true;
}

/** The most force-loaded chunks read from one dimension; a world has a handful. */
const MAX_FORCED = 100_000;

/** Chunk coordinates in an unpacked ChunkPos long: x in the low 32 bits, z in the high 32. */
function unpackChunkPos(packed) {
  const v = BigInt(packed);
  return { x: Number(BigInt.asIntN(32, v)), z: Number(BigInt.asIntN(32, v >> 32n)) };
}

/**
 * The chunks a dimension keeps loaded with /forceload, as `[{x, z}]` in chunk
 * coordinates, from <dimension>/data/chunks.dat. Recognised spellings: a packed
 * long array under `Forced` (up to 1.21.x) and ticket entries that carry a
 * `chunk_pos` int pair. A missing file means none; one that cannot be read is
 * reported in `issues.forcedUnreadable`, because those chunks then go
 * unprotected.
 */
function readForcedChunks(dimDir, issues = null) {
  const file = path.join(dimDir, "data", "chunks.dat");
  let doc;
  try {
    if (!fs.existsSync(file)) return [];
    const raw = fs.readFileSync(file);
    doc = parseNbt(raw[0] === 0x1f && raw[1] === 0x8b ? zlib.gunzipSync(raw) : raw, { bigLongs: true });
  } catch {
    if (issues) issues.forcedUnreadable = true;
    return [];
  }
  const out = [];
  const visit = (node, depth) => {
    if (!node || typeof node !== "object" || depth > 6 || out.length >= MAX_FORCED) return;
    if (Array.isArray(node)) {
      for (const item of node) visit(item, depth + 1);
      return;
    }
    if (Array.isArray(node.Forced)) {
      for (const packed of node.Forced) if (typeof packed === "bigint" && out.length < MAX_FORCED) out.push(unpackChunkPos(packed));
    }
    if (Array.isArray(node.chunk_pos) && node.chunk_pos.length === 2 && node.chunk_pos.every((n) => typeof n === "number")) {
      out.push({ x: node.chunk_pos[0], z: node.chunk_pos[1] });
    }
    for (const value of Object.values(node)) visit(value, depth + 1);
  };
  visit(doc, 0);
  return out;
}

module.exports = {
  CHUNK_FOLDERS,
  DIMENSION_IDS,
  worldDirOf,
  discoverDimensions,
  readSpawn,
  readPlayerPositions,
  readForcedChunks,
  dimensionIdOf,
  normalizeDimensionId,
};
