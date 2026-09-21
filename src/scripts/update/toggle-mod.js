// scripts/update/toggle-mod.js
//
// Disables or re-enables an installed mod without uninstalling it: moves its
// jar between mods/ and mods/disabled/ so the loader does (or doesn't) load
// it, but leaves its downloaded_versions.json entry untouched — it's still
// "installed" for update-checking purposes either way. Reversible; takes
// effect on the server's next start.
//
// Usage:
//   node toggle-mod.js <slug-or-project-id> --enable  [--json]
//   node toggle-mod.js <slug-or-project-id> --disable [--json]
//
// Idempotent: toggling to the state a mod is already in is a no-op success.

const fs = require("fs");
const path = require("path");
const { parseArgs } = require("./lib/args");
const { resolveDirs, readManifest, resolveEntry, locateJar } = require("./lib/toggle-mod-common");

const cliArgs = parseArgs({
  flags: { slug: null },
  boolFlags: ["enable", "disable", "json"],
  positional: ["slug"],
});

const JSON_MODE = cliArgs.bool("json");
const _realLog = console.log.bind(console);
if (JSON_MODE) {
  console.log = () => {};
  console.error = () => {};
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

const wantEnable = cliArgs.bool("enable");
const wantDisable = cliArgs.bool("disable");
if (wantEnable === wantDisable) {
  fail(
    "error",
    "Usage: node toggle-mod.js <slug-or-project-id> --enable|--disable [--json]",
  );
}

const slug = cliArgs.get("slug");
if (!slug) {
  fail(
    "error",
    "Usage: node toggle-mod.js <slug-or-project-id> --enable|--disable [--json]",
  );
}

function main() {
  const { modsDir, disabledDir } = resolveDirs();
  const downloadedVersions = readManifest();
  const { key, recordedFilename } = resolveEntry(downloadedVersions, slug);

  const jar = locateJar(modsDir, disabledDir, key, recordedFilename);
  if (!jar) {
    fail(
      "jar-missing",
      `"${key}" is installed but its jar could not be found in mods/ or mods/disabled/.`,
    );
  }

  if (jar.enabled === wantEnable) {
    const verb = wantEnable ? "enabled" : "disabled";
    console.log(`"${key}" is already ${verb}.`);
    if (JSON_MODE) {
      emitJson({
        ok: true,
        slug: key,
        filename: jar.filename,
        ...(wantEnable ? { alreadyEnabled: true } : { alreadyDisabled: true }),
      });
    }
    return;
  }

  const targetDir = wantEnable ? modsDir : disabledDir;
  fs.mkdirSync(targetDir, { recursive: true });
  const target = path.join(targetDir, jar.filename);
  fs.renameSync(jar.currentPath, target);

  const verb = wantEnable ? "Enabled" : "Disabled";
  const dest = wantEnable ? "mods/" : "mods/disabled/";
  console.log(`${verb} "${key}": moved ${jar.filename} to ${dest}.`);

  if (JSON_MODE) emitJson({ ok: true, slug: key, filename: jar.filename });
  else console.log("Done.");
}

try {
  main();
} catch (err) {
  fail(err.code || "error", err.message);
}
