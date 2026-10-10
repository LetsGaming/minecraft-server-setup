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
const { loadVariables } = require("./variables");
const { detectInstalledJars } = require("./jars");

const variablesPath = path.resolve(__dirname, "..", "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "..",
  "common",
  "downloaded_versions.json",
);

/** Resolve SERVER_PATH and derive the enabled/disabled mod directories. */
function resolveDirs() {
  const vars = loadVariables(variablesPath, { optional: true });
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
    : [...detectInstalledJars(modsDir, key), ...detectInstalledJars(disabledDir, key)].map(
        (jar) => jar.file,
      );

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
