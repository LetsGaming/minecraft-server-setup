const fs = require("fs");
const path = require("path");
const axios = require("axios");
const { fetchManifest } = require("./download_utils");
const { pickVersion } = require("../../scripts/update/lib/versions");

const MODS_DIR = path.resolve(__dirname, "..", "..", "vanilla", "download");
const FABRIC_GAME_URL = "https://meta.fabricmc.net/v2/versions/game";
const MODRINTH_API = "https://api.modrinth.com/v2";
const GROUPS = ["performance", "utility", "optional"];
const DEFAULT_GROUPS = ["performance", "utility"];
const DEFAULT_LOOKBACK = 3;
const LOADER = "fabric";
const REQUEST_TIMEOUT_MS = 15000;
const TIMEOUT_CODES = new Set(["ECONNABORTED", "ETIMEDOUT"]);

function parseSlugs(text) {
  return String(text)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

function readGroupSlugs(groups, dir = MODS_DIR) {
  const slugs = [];
  for (const group of groups) {
    if (!GROUPS.includes(group)) {
      throw new Error(`Unknown mod group "${group}". Known groups: ${GROUPS.join(", ")}.`);
    }
    const file = path.join(dir, `${group}_mods.txt`);
    if (!fs.existsSync(file)) throw new Error(`Missing mod list ${file}.`);
    for (const slug of parseSlugs(fs.readFileSync(file, "utf8"))) {
      if (!slugs.includes(slug)) slugs.push(slug);
    }
  }
  return slugs;
}

/** Modrinth answers 404 for a slug that does not exist; that is a missing mod, not an outage. */
async function fetchModVersions(slug, get) {
  try {
    const resp = await get(`${MODRINTH_API}/project/${encodeURIComponent(slug)}/version`);
    return resp.data || [];
  } catch (err) {
    if (err.response?.status === 404) return [];
    throw err;
  }
}

function asTimeoutError(err) {
  if (TIMEOUT_CODES.has(err?.code) || /timeout/i.test(err?.message || "")) {
    return new Error("A request timed out; check your internet connection and try again.");
  }
  return err;
}

/**
 * @param {{ slugs: string[], lookback?: number, version?: string, deps?: { fetchManifest?: Function, get?: Function } }} opts
 * @returns {Promise<{ minecraft: string, notices: Array<{severity: string, text: string}>, dropped: string[] }>}
 */
async function resolveDefaultVersion(opts) {
  try {
    return await resolveVersion(opts);
  } catch (err) {
    throw asTimeoutError(err);
  }
}

async function resolveVersion({ slugs, lookback = DEFAULT_LOOKBACK, version, deps = {} }) {
  const getManifest = deps.fetchManifest || (() => fetchManifest({ timeout: REQUEST_TIMEOUT_MS }));
  const get = deps.get || ((url) => axios.get(url, { timeout: REQUEST_TIMEOUT_MS }));

  let candidates;
  if (version) {
    candidates = [version];
  } else {
    const manifest = await getManifest();
    candidates = manifest.versions
      .filter((v) => v.type === "release")
      .slice(0, lookback)
      .map((v) => v.id);
    if (candidates.length === 0) throw new Error("The Mojang manifest lists no release versions.");
  }

  const fabricGames = (await get(FABRIC_GAME_URL)).data || [];
  const fabricStable = new Set(fabricGames.filter((g) => g.stable).map((g) => g.version));

  const modVersions = {};
  for (const slug of slugs) modVersions[slug] = await fetchModVersions(slug, get);

  const evaluated = candidates.map((version) => ({
    version,
    fabric: fabricStable.has(version),
    missing: slugs.filter((slug) => !pickVersion(modVersions[slug], version, LOADER)),
  }));

  const usable = evaluated.filter((c) => c.fabric);
  if (usable.length === 0) {
    throw new Error(
      version
        ? `Fabric has no stable loader for Minecraft ${version}.`
        : `Fabric has no stable loader for any of: ${candidates.join(", ")}.`,
    );
  }

  let chosen = usable.find((c) => c.missing.length === 0);
  const notices = [];
  let dropped = [];
  if (!chosen && version) {
    chosen = usable[0];
    dropped = chosen.missing;
    notices.push({
      severity: "adjusted",
      text: `These mods have no build for Minecraft ${version} and are excluded: ${dropped.join(", ")}.`,
    });
  } else if (!chosen) {
    chosen = usable.reduce((best, c) => (c.missing.length < best.missing.length ? c : best));
    dropped = chosen.missing;
    notices.push({
      severity: "adjusted",
      text:
        `No Minecraft version among the newest ${candidates.length} releases has a build of every mod. ` +
        `Using ${chosen.version}; these mods have no build for it and are excluded: ${dropped.join(", ")}.`,
    });
  } else if (chosen.version !== candidates[0]) {
    const newest = evaluated[0];
    const reason = !newest.fabric
      ? "Fabric has no loader for it"
      : `mod ${newest.missing.join(", ")} has no build for it`;
    notices.push({
      severity: "adjusted",
      text: `${newest.version} was skipped because ${reason}; using ${chosen.version}.`,
    });
  }

  return { minecraft: chosen.version, notices, dropped };
}

function parseArgs(argv) {
  const opts = { groups: DEFAULT_GROUPS, lookback: DEFAULT_LOOKBACK };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${arg} needs a value.`);
      return argv[++i];
    };
    if (arg === "--groups") {
      opts.groups = value().split(",").map((g) => g.trim()).filter(Boolean);
    } else if (arg === "--lookback") {
      const raw = value();
      opts.lookback = Number(raw);
      if (!Number.isInteger(opts.lookback) || opts.lookback < 1) {
        throw new Error(`--lookback must be a positive whole number, got "${raw}".`);
      }
    } else if (arg === "--version") {
      opts.version = value().trim();
      if (!opts.version) throw new Error("--version needs a value.");
    } else {
      throw new Error(`Unknown argument ${arg}.`);
    }
  }
  return opts;
}

async function main(argv) {
  const opts = parseArgs(argv);
  const slugs = readGroupSlugs(opts.groups);
  const result = await resolveDefaultVersion({ slugs, lookback: opts.lookback, version: opts.version });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    console.error(`resolve_default_version: ${err.message}`);
    process.exitCode = 1;
  });
}

module.exports = { parseSlugs, readGroupSlugs, resolveDefaultVersion, parseArgs };
