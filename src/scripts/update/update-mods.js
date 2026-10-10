const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const axios = require("axios");
const { parseArgs } = require("./lib/args");
const { loadVariables } = require("./lib/variables");
const { detectInstalledJars } = require("./lib/jars");
const { createJsonMode } = require("./lib/json-mode");

// Usage:
//   node update-mods.js [mcVersion] [--mcVersion=<ver>] [--migrate]
//
//   mcVersion  Target MC version — positional or --mcVersion=.
//              Falls back to gameVersion in downloaded_versions.json.
//   --migrate  Migrate legacy string entries in downloaded_versions.json to
//              { versionId, filename } format. No download is performed.

// ---------------- machine-readable mode ----------------
//
// With --json the wrapper drives this script and needs one JSON object on
// stdout. We silence the human channels here so only the final emit reaches
// stdout; human mode (no --json) is unaffected.
const JSON_MODE = process.argv.includes("--json");
const jsonMode = createJsonMode(JSON_MODE, { silenceWarn: true });
const emitJson = jsonMode.emit;

// ---------------- paths ----------------

const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "common",
  "downloaded_versions.json",
);

// ---------------- helpers ----------------

function safeUnlink(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
      console.log(`Removed old mod: ${path.basename(filePath)}`);
    }
  } catch (err) {
    console.error(`Failed to remove ${filePath}: ${err.message}`);
  }
}

// ---------------- detection ----------------

// ---------------- migration ----------------

function migrateDownloadedVersions(downloadedVersions, modsDir) {
  let changed = false;

  for (const [slug, value] of Object.entries(downloadedVersions.mods)) {
    if (typeof value !== "string") continue;

    console.log(`Migrating legacy entry: ${slug}`);

    const matches = detectInstalledJars(modsDir, slug);

    if (matches.length === 1) {
      downloadedVersions.mods[slug] = {
        versionId: value,
        filename: matches[0].file,
      };
      console.log(`  locked to ${matches[0].file}`);
    } else if (matches.length === 0) {
      downloadedVersions.mods[slug] = {
        versionId: value,
        filename: null,
      };
      console.warn(`  no installed jar found`);
    } else {
      throw new Error(
        `Ambiguous jars for ${slug}: ${matches.map((m) => m.file).join(", ")}`,
      );
    }

    changed = true;
  }

  if (changed) {
    fs.writeFileSync(
      downloadedVersionsPath,
      JSON.stringify(downloadedVersions, null, 2),
      "utf8",
    );
    console.log("Migration completed successfully.");
  } else {
    console.log("No legacy entries found. Nothing to migrate.");
  }
}

// ---------------- update logic ----------------

function runCheckUpdates(version) {
  console.log(`Checking for mod updates for game version: ${version}`);
  return new Promise((resolve, reject) => {
    const checkUpdatesPath = path.resolve(__dirname, "check-updates.js");
    execFile(
      "node",
      [checkUpdatesPath, version, "--json"],
      (err, stdout, stderr) => {
        if (err) {
          return reject(
            new Error(
              `Failed to run check-updates.js: ${stderr || err.message}`,
            ),
          );
        }

        try {
          resolve(JSON.parse(stdout));
        } catch {
          reject(
            new Error("Failed to parse JSON output from check-updates.js"),
          );
        }
      },
    );
  });
}

async function downloadFile(url, targetPath) {
  const response = await axios({
    url,
    method: "GET",
    responseType: "stream",
    validateStatus: (s) => s >= 200 && s < 300,
  });

  return new Promise((resolve, reject) => {
    const writer = fs.createWriteStream(targetPath);
    response.data.pipe(writer);
    writer.on("error", reject);
    writer.on("close", resolve);
  });
}

// ---------------- update runner ----------------

/**
 * Update installed mods to their latest compatible build.
 *
 * `only` restricts the run to a single slug, which is how update-mod.js reuses
 * this for one mod. Returns a summary; it neither emits JSON nor exits, so both
 * the CLI here and update-mod.js can decide how to report.
 */
async function runUpdates({ mcVersion = null, only = null } = {}) {
  const vars = loadVariables(variablesPath);
  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) {
    throw new Error(`Invalid SERVER_PATH: ${serverPath}`);
  }

  const modsDir = path.join(serverPath, "mods");
  const disabledDir = path.join(modsDir, "disabled");
  fs.mkdirSync(modsDir, { recursive: true });

  const downloadedVersions = JSON.parse(
    fs.readFileSync(downloadedVersionsPath, "utf8"),
  );
  downloadedVersions.mods ??= {};

  const version = mcVersion || downloadedVersions.gameVersion || "latest";
  const { results } = await runCheckUpdates(version);

  // Restrict to one mod when asked. A slug that is not in the check results is
  // not installed, so report it rather than silently doing nothing.
  let scoped = results;
  if (only) {
    scoped = results.filter((m) => m.slug === only);
    if (scoped.length === 0) {
      return {
        updated: [],
        upToDate: [],
        failed: [{ slug: only, error: "Mod is not installed." }],
      };
    }
  }

  const updated = [];
  const upToDate = [];
  const failed = [];

  for (const mod of scoped) {
    if (mod.status !== "update_available") {
      console.log(`No update available for: ${mod.slug}\n`);
      upToDate.push(mod.slug);
      continue;
    }
    if (!mod.downloadUrl) continue;

    try {
      const filename = decodeURIComponent(
        path.basename(new URL(mod.downloadUrl).pathname),
      );

      // An update must not silently flip a disabled mod back on: the new jar
      // goes into whichever directory the old one is currently sitting in
      // (mods/ or mods/disabled/), and only that directory is searched for
      // the old jar to remove. See toggle-mod.js for why state lives here.
      const previous = downloadedVersions.mods[mod.slug];
      const currentDir =
        previous?.filename && fs.existsSync(path.join(disabledDir, previous.filename))
          ? disabledDir
          : modsDir;

      const targetPath = path.join(currentDir, filename);
      const tempPath = `${targetPath}.tmp`;

      console.log(`Updating mod: ${mod.slug} to version ${mod.latestVersionId}`);
      await downloadFile(mod.downloadUrl, tempPath);

      if (previous?.filename) {
        safeUnlink(path.join(currentDir, previous.filename));
      } else {
        for (const jar of detectInstalledJars(currentDir, mod.slug, filename)) {
          safeUnlink(jar.fullPath);
        }
      }

      fs.renameSync(tempPath, targetPath);
      downloadedVersions.mods[mod.slug] = {
        versionId: mod.latestVersionId,
        filename,
      };
      fs.writeFileSync(
        downloadedVersionsPath,
        JSON.stringify(downloadedVersions, null, 2),
        "utf8",
      );
      console.log(`Downloaded and installed: ${filename}\n`);
      updated.push({ slug: mod.slug, toVersionId: mod.latestVersionId, filename });
    } catch (err) {
      // One mod failing must not abort the rest of a batch.
      console.error(`Failed to update ${mod.slug}: ${err.message}`);
      failed.push({ slug: mod.slug, error: err.message });
    }
  }

  console.log("Mod updates completed.");
  return { updated, upToDate, failed };
}

/** Report a fatal failure in the caller's chosen channel and exit non-zero. */
function failWith(code, message) {
  if (JSON_MODE) emitJson({ ok: false, error: message, code });
  else console.error("Error:", message);
  process.exit(1);
}

// ---------------- CLI ----------------

async function main() {
  try {
    const args = parseArgs({
      flags: { mcVersion: null },
      boolFlags: ["migrate", "json"],
      positional: ["mcVersion"],
    });

    if (args.bool("migrate")) {
      const vars = loadVariables(variablesPath);
      const serverPath = vars.SERVER_PATH;
      if (!serverPath || !fs.existsSync(serverPath)) {
        throw new Error(`Invalid SERVER_PATH: ${serverPath}`);
      }
      const modsDir = path.join(serverPath, "mods");
      const downloadedVersions = JSON.parse(
        fs.readFileSync(downloadedVersionsPath, "utf8"),
      );
      downloadedVersions.mods ??= {};
      migrateDownloadedVersions(downloadedVersions, modsDir);
      if (JSON_MODE) emitJson({ ok: true, migrated: true });
      return;
    }

    const summary = await runUpdates({ mcVersion: args.get("mcVersion") });
    if (JSON_MODE) emitJson({ ok: true, ...summary });
  } catch (err) {
    failWith("error", err.message);
  }
}

module.exports = { runUpdates, emitJson, failWith, JSON_MODE };

if (require.main === module) main();
