// scripts/update/lib/toggle-mod-common.js
//
// Shared logic for toggle-mod.js: enabled/disabled state
// lives entirely in where the jar sits on disk (mods/ vs mods/disabled/),
// not in downloaded_versions.json — a location can't drift from itself the
// way a flag mirroring it could. The manifest is only consulted to resolve a
// slug to its recorded filename (same lookup remove-mod.js already does);
// legacy entries with no recorded filename fall back to a slug scan of both
// directories, mirroring remove-mod.js's detectInstalledJars.

const fs = require("fs");
const path = require("path");

const variablesPath = path.resolve(__dirname, "..", "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "..",
  "common",
  "downloaded_versions.json",
);

function loadVariables() {
  if (!fs.existsSync(variablesPath)) return {};
  const vars = {};
  for (const line of fs.readFileSync(variablesPath, "utf8").split(/\r?\n/)) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    vars[match[1]] = value;
  }
  return vars;
}

function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Real jar files whose name carries this slug, in one directory. */
function detectSlugJars(dir, modSlug) {
  if (!fs.existsSync(dir)) return [];
  const slugRegex = new RegExp(
    `(^|[-_.])${escapeRegex(modSlug)}([-.+_]|$).*\\.jar$`,
    "i",
  );
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".jar") && slugRegex.test(f))
    .filter((f) => {
      try {
        const stat = fs.lstatSync(path.join(dir, f));
        return stat.isFile() && !stat.isSymbolicLink();
      } catch {
        return false;
      }
    });
}

/** Resolve SERVER_PATH and derive the enabled/disabled mod directories. */
function resolveDirs() {
  const vars = loadVariables();
  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) {
    throw Object.assign(new Error(`Invalid SERVER_PATH: "${serverPath}"`), {
      code: "error",
    });
  }
  const modsDir = path.join(serverPath, "mods");
  const disabledDir = path.join(modsDir, "disabled");
  return { modsDir, disabledDir };
}

function readManifest() {
  if (!fs.existsSync(downloadedVersionsPath)) {
    throw Object.assign(new Error("downloaded_versions.json not found."), {
      code: "manifest",
    });
  }
  let downloadedVersions;
  try {
    downloadedVersions = JSON.parse(
      fs.readFileSync(downloadedVersionsPath, "utf8"),
    );
  } catch {
    throw Object.assign(
      new Error("Could not parse downloaded_versions.json."),
      { code: "manifest" },
    );
  }
  downloadedVersions.mods ??= {};
  return downloadedVersions;
}

/**
 * Resolve a slug to its manifest key + recorded filename (if any). Throws
 * with `code: "not-installed"` when the slug isn't in the manifest at all.
 */
function resolveEntry(downloadedVersions, slug) {
  const key =
    downloadedVersions.mods[slug] !== undefined
      ? slug
      : Object.keys(downloadedVersions.mods).find((k) => k === slug);
  const entry = key ? downloadedVersions.mods[key] : undefined;
  if (entry === undefined) {
    throw Object.assign(new Error(`Mod "${slug}" is not installed.`), {
      code: "not-installed",
    });
  }
  const recordedFilename = typeof entry === "string" ? null : (entry.filename ?? null);
  return { key, recordedFilename };
}

/**
 * Find where a mod's jar currently sits: the recorded filename wins when
 * present (checked in both directories, in case it drifted); otherwise fall
 * back to a slug scan of both directories, same fallback remove-mod.js uses.
 * Returns null if the jar can't be found anywhere — a manifest entry with no
 * matching file on disk (already-broken state this script can't fix).
 */
function locateJar(modsDir, disabledDir, key, recordedFilename) {
  const candidates = recordedFilename
    ? [recordedFilename]
    : [...detectSlugJars(modsDir, key), ...detectSlugJars(disabledDir, key)];

  for (const filename of candidates) {
    const enabledPath = path.join(modsDir, filename);
    if (fs.existsSync(enabledPath)) return { filename, enabled: true, currentPath: enabledPath };
    const disabledPath = path.join(disabledDir, filename);
    if (fs.existsSync(disabledPath)) return { filename, enabled: false, currentPath: disabledPath };
  }
  return null;
}

module.exports = {
  resolveDirs,
  readManifest,
  resolveEntry,
  locateJar,
};
