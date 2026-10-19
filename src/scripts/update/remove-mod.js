// scripts/update/remove-mod.js
//
// Removes a single installed mod: deletes its jar from the server's mods
// directory and drops its entry from downloaded_versions.json.
//
// Usage:
//   node remove-mod.js <slug-or-project-id> [--json]
//
//   slug   The key under mods in downloaded_versions.json — positional or
//          --slug=. Also matches a legacy entry stored under its project id.
//   --json Emit one JSON object instead of the human log (used by the wrapper).
//
// Dependency handling: the manifest does not record a dependency graph, so a
// dependency pulled in only for this mod cannot be identified offline. Nothing
// is auto-removed and no orphan list is reported; the operator decides.
// (Resolving true orphans needs Modrinth and belongs on the dashboard.)
//
// Also checks mods/disabled/ (see toggle-mod.js) — a disabled mod is still
// "installed" as far as the manifest is concerned, so removing it must find
// its jar wherever it currently sits, not just in mods/.

const fs = require("fs");
const path = require("path");
// Serialized with other mod changes and with restore, rollback and upgrade
// (S-024): re-runs this script under the instance's operation lock.
require("./lib/opLock").guardModOperation();
const { readManifest, writeManifest } = require("./lib/manifest");
const { parseArgs } = require("./lib/args");
const { loadVariables } = require("./lib/variables");
const { detectInstalledJars } = require("./lib/jars");
const { createJsonMode } = require("./lib/json-mode");

// ── Paths ─────────────────────────────────────────────────────────────────
const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "common",
  "downloaded_versions.json",
);

// ── CLI args ──────────────────────────────────────────────────────────────
const cliArgs = parseArgs({
  flags: { slug: null },
  boolFlags: ["json"],
  positional: ["slug"],
});

const JSON_MODE = cliArgs.bool("json");
const jsonMode = createJsonMode(JSON_MODE, { captureErrors: true });
const emitJson = jsonMode.emit;
function fail(code, message) {
  if (JSON_MODE) {
    emitJson({ ok: false, error: message, code });
  } else {
    console.error(message);
  }
  process.exit(1);
}

const slug = cliArgs.get("slug");
if (!slug) {
  fail("error", "Usage: node remove-mod.js <slug-or-project-id> [--json]");
}

// ── Helpers ───────────────────────────────────────────────────────────────
// ── Main ──────────────────────────────────────────────────────────────────
function main() {
  const vars = loadVariables(variablesPath, { optional: true });
  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) {
    fail("error", `Invalid SERVER_PATH: "${serverPath}"`);
  }
  const modsDir = path.join(serverPath, "mods");
  const disabledDir = path.join(modsDir, "disabled");

  let downloadedVersions;
  try {
    downloadedVersions = readManifest(downloadedVersionsPath);
  } catch (err) {
    fail("manifest", err.message);
  }
  downloadedVersions.mods ??= {};

  // Match by canonical slug, falling back to a legacy project-id key.
  const key =
    downloadedVersions.mods[slug] !== undefined
      ? slug
      : Object.keys(downloadedVersions.mods).find((k) => k === slug);
  const entry = key ? downloadedVersions.mods[key] : undefined;
  if (entry === undefined) {
    fail("not-installed", `Mod "${slug}" is not installed.`);
  }

  // A new entry records its filename; a legacy one may be a bare version-id
  // string or a null filename — fall back to a slug scan of the mods dir.
  const recordedFilename =
    typeof entry === "string" ? null : (entry.filename ?? null);

  // S-008: a recorded filename names exactly this mod's jar, so only that file
  // goes. The slug scan used to run as well, and its token match also took
  // other mods' jars (removing "sodium" deleted sodium-extra). The scan is
  // only for legacy entries without a filename, and refuses to guess between
  // several jars.
  const toRemove = new Set();
  if (recordedFilename) {
    if (path.basename(recordedFilename) !== recordedFilename) {
      fail("manifest", `The recorded filename for "${key}" is not a plain file name.`);
    }
    toRemove.add(path.join(modsDir, recordedFilename));
    toRemove.add(path.join(disabledDir, recordedFilename));
  } else {
    const found = [...detectInstalledJars(modsDir, key), ...detectInstalledJars(disabledDir, key)];
    if (found.length > 1) {
      fail(
        "ambiguous",
        `Several jars match "${key}" (${found.map((j) => j.file).join(", ")}); remove the right one by hand.`,
      );
    }
    for (const jar of found) toRemove.add(jar.fullPath);
  }

  let removedFile = null;
  const failures = [];
  for (const jarPath of toRemove) {
    try {
      if (fs.existsSync(jarPath)) {
        fs.unlinkSync(jarPath);
        removedFile = removedFile ?? path.basename(jarPath);
        console.log(`Removed jar: ${path.basename(jarPath)}`);
      }
    } catch (err) {
      console.error(`Failed to remove ${jarPath}: ${err.message}`);
      failures.push(`${path.basename(jarPath)} (${err.message})`);
    }
  }
  // The entry is the record that the jar is there: dropping it while the jar
  // stays would leave a mod the server loads and nothing tracks.
  if (failures.length > 0) {
    fail("remove-failed", `Could not delete ${failures.join(", ")}; "${key}" is still registered.`);
  }

  delete downloadedVersions.mods[key];
  writeManifest(downloadedVersionsPath, downloadedVersions);
  console.log(`Removed "${key}" from downloaded_versions.json.`);

  if (JSON_MODE) {
    emitJson({ ok: true, slug: key, removedFile });
  } else {
    console.log("Done.");
  }
}

try {
  main();
} catch (err) {
  fail("error", err.message);
}
