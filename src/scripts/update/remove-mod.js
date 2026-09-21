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
// is auto-removed; orphanedDependencies is reported empty, and the operator
// decides. (Resolving true orphans needs Modrinth and belongs on the dashboard.)
//
// Also checks mods/disabled/ (see toggle-mod.js) — a disabled mod is still
// "installed" as far as the manifest is concerned, so removing it must find
// its jar wherever it currently sits, not just in mods/.

const fs = require("fs");
const path = require("path");
const { parseArgs } = require("./lib/args");

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
const _realLog = console.log.bind(console);
let _lastError = null;
if (JSON_MODE) {
  console.log = () => {};
  console.error = (...a) => {
    _lastError = a.map(String).join(" ");
  };
}
function emitJson(obj) {
  _realLog(JSON.stringify(obj));
}
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

/** Real jar files whose name carries this slug (for legacy null-filename entries). */
function detectInstalledJars(modsDir, modSlug) {
  if (!fs.existsSync(modsDir)) return [];
  const slugRegex = new RegExp(
    `(^|[-_.])${escapeRegex(modSlug)}([-.+_]|$).*\\.jar$`,
    "i",
  );
  return fs
    .readdirSync(modsDir)
    .filter((f) => f.endsWith(".jar") && slugRegex.test(f))
    .map((f) => path.join(modsDir, f))
    .filter((full) => {
      try {
        const stat = fs.lstatSync(full);
        return stat.isFile() && !stat.isSymbolicLink();
      } catch {
        return false;
      }
    });
}

// ── Main ──────────────────────────────────────────────────────────────────
function main() {
  const vars = loadVariables();
  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) {
    fail("error", `Invalid SERVER_PATH: "${serverPath}"`);
  }
  const modsDir = path.join(serverPath, "mods");
  const disabledDir = path.join(modsDir, "disabled");

  if (!fs.existsSync(downloadedVersionsPath)) {
    fail("manifest", "downloaded_versions.json not found.");
  }
  let downloadedVersions;
  try {
    downloadedVersions = JSON.parse(
      fs.readFileSync(downloadedVersionsPath, "utf8"),
    );
  } catch {
    fail("manifest", "Could not parse downloaded_versions.json.");
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

  const toRemove = new Set();
  if (recordedFilename) {
    toRemove.add(path.join(modsDir, recordedFilename));
    toRemove.add(path.join(disabledDir, recordedFilename));
  }
  for (const jar of detectInstalledJars(modsDir, key)) toRemove.add(jar);
  for (const jar of detectInstalledJars(disabledDir, key)) toRemove.add(jar);

  let removedFile = null;
  for (const jarPath of toRemove) {
    try {
      if (fs.existsSync(jarPath)) {
        fs.unlinkSync(jarPath);
        removedFile = removedFile ?? path.basename(jarPath);
        console.log(`Removed jar: ${path.basename(jarPath)}`);
      }
    } catch (err) {
      console.error(`Failed to remove ${jarPath}: ${err.message}`);
    }
  }

  delete downloadedVersions.mods[key];
  const tmp = `${downloadedVersionsPath}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(downloadedVersions, null, 2), "utf8");
  fs.renameSync(tmp, downloadedVersionsPath);
  console.log(`Removed "${key}" from downloaded_versions.json.`);

  if (JSON_MODE) {
    emitJson({ ok: true, slug: key, removedFile, orphanedDependencies: [] });
  } else {
    console.log("Done.");
  }
}

try {
  main();
} catch (err) {
  fail("error", err.message);
}
