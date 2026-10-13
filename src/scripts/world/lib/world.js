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
 * Dimensions found on disk: the overworld at the world root, the Nether and the
 * End in their own folders, and datapack dimensions under dimensions/<ns>/<name>.
 * Discovered, not assumed: a folder counts only when it holds a region folder.
 *
 * @returns {Array<{id: string, dir: string}>}
 */
function discoverDimensions(worldDir) {
  const found = [];
  const add = (id, dir) => {
    if (isDir(path.join(dir, "region"))) found.push({ id, dir });
  };
  add(DIMENSION_IDS.OVERWORLD, worldDir);
  add(DIMENSION_IDS.NETHER, path.join(worldDir, "DIM-1"));
  add(DIMENSION_IDS.END, path.join(worldDir, "DIM1"));

  const custom = path.join(worldDir, "dimensions");
  if (isDir(custom)) {
    for (const ns of safeReaddir(custom)) {
      const nsDir = path.join(custom, ns);
      if (!isDir(nsDir)) continue;
      for (const name of safeReaddir(nsDir)) {
        add(`${ns}:${name}`, path.join(nsDir, name));
      }
    }
  }
  return found;
}

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
  if (typeof value === "string") return value.replace(/^minecraft:/, "");
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
 * Where each known player last was: `[{dimension, x, z}]` in block coordinates,
 * from playerdata/*.dat. A file that cannot be read is skipped; that player
 * simply is not protected by position.
 */
function readPlayerPositions(worldDir) {
  const dir = path.join(worldDir, "playerdata");
  const out = [];
  for (const name of safeReaddir(dir)) {
    if (!name.endsWith(".dat")) continue;
    try {
      const nbt = readNbtFile(path.join(dir, name));
      const pos = nbt.Pos;
      if (Array.isArray(pos) && pos.length >= 3) {
        out.push({ dimension: dimensionIdOf(nbt.Dimension), x: pos[0], z: pos[2] });
      }
    } catch {
      /* unreadable player file */
    }
  }
  return out;
}

module.exports = {
  CHUNK_FOLDERS,
  DIMENSION_IDS,
  worldDirOf,
  discoverDimensions,
  readSpawn,
  readPlayerPositions,
  dimensionIdOf,
};
