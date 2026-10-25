const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const { parseArgs } = require("./lib/args");
const { loadVariables } = require("./lib/variables");
const { detectInstalledJars } = require("./lib/jars");
const { createJsonMode } = require("./lib/json-mode");
const { safeFilenameFromUrl, downloadToTemp } = require("./lib/download");
const { writeManifest } = require("./lib/manifest");
const { isXaeroSlug, applyXaeroConfig } = require("./lib/xaero");

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
    writeManifest(downloadedVersionsPath, downloadedVersions);
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

/** Install a required dependency by project id through add-mod.js; resolves to its slug. */
function installDependency(projectId) {
  return new Promise((resolve, reject) => {
    execFile(
      process.execPath,
      [path.resolve(__dirname, "add-mod.js"), projectId, "--json"],
      { env: { ...process.env, MC_OPERATION_LOCK_HELD: "1" } },
      (err, stdout, stderr) => {
        let out = null;
        try {
          out = JSON.parse(stdout.trim().split("\n").filter(Boolean).pop());
        } catch {
          /* no JSON: fall through to the error */
        }
        if (!err && out?.ok) return resolve(out.slug ?? projectId);
        reject(new Error(out?.error ?? (stderr || err?.message || "add-mod.js failed").trim()));
      },
    );
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

  // Projects the check saw installed, by project id; a required dependency that
  // is among them needs nothing.
  const installedProjectIds = new Set(results.map((m) => m.projectId).filter(Boolean));

  for (const mod of scoped) {
    if (mod.status === "up_to_date") {
      console.log(`No update available for: ${mod.slug}\n`);
      upToDate.push(mod.slug);
      continue;
    }
    if (mod.status !== "update_available") {
      // error, no_versions, no_matching_version, invalid_entry: the mod was not
      // checked or has no build to move to, which is not the same as being current.
      const reason = mod.error ?? mod.message ?? mod.status;
      console.error(`Could not check ${mod.slug}: ${reason}`);
      failed.push({ slug: mod.slug, error: String(reason) });
      continue;
    }
    if (!mod.downloadUrl) {
      failed.push({ slug: mod.slug, error: "The update lists no download." });
      continue;
    }

    try {
      const filename = safeFilenameFromUrl(mod.downloadUrl);

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
      await downloadToTemp(mod.downloadUrl, tempPath, {
        sha512: mod.downloadSha512 || undefined,
      });

      // The new jar goes in by rename before the old one is deleted, so a
      // failure in between leaves two builds rather than none. A new file name
      // sits next to the old one for a moment; the same name replaces it.
      fs.renameSync(tempPath, targetPath);
      downloadedVersions.mods[mod.slug] = {
        versionId: mod.latestVersionId,
        filename,
      };
      writeManifest(downloadedVersionsPath, downloadedVersions);

      const oldJars = previous?.filename
        ? [path.join(currentDir, previous.filename)]
        : detectInstalledJars(currentDir, mod.slug, filename).map((jar) => jar.fullPath);
      for (const oldJar of oldJars) {
        if (path.resolve(oldJar) !== path.resolve(targetPath)) safeUnlink(oldJar);
      }
      console.log(`Downloaded and installed: ${filename}\n`);
      updated.push({ slug: mod.slug, toVersionId: mod.latestVersionId, filename });

      // A new build can need a mod the old one did not. Without it the server
      // fails to start after the next restart.
      for (const dep of mod.requiredDependencies ?? []) {
        if (installedProjectIds.has(dep.projectId)) continue;
        try {
          const added = await installDependency(dep.projectId);
          installedProjectIds.add(dep.projectId);
          console.log(`Installed required dependency: ${added}\n`);
        } catch (depErr) {
          console.error(`Failed to install dependency ${dep.projectId} of ${mod.slug}: ${depErr.message}`);
          failed.push({ slug: mod.slug, error: `Updated, but its required dependency ${dep.projectId} could not be installed: ${depErr.message}` });
        }
      }
    } catch (err) {
      // One mod failing must not abort the rest of a batch.
      console.error(`Failed to update ${mod.slug}: ${err.message}`);
      failed.push({ slug: mod.slug, error: err.message });
    }
  }

  if (updated.some((u) => isXaeroSlug(u.slug))) {
    await applyXaeroConfig(variablesPath, serverPath);
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

if (require.main === module) {
  require("./lib/args").exitOnHelp("Usage: node update-mods.js [mcVersion] [--mcVersion=<ver>] [--migrate] [--json]");
  // Serialized with other mod changes and with restore, rollback and upgrade
  // (S-024): re-runs this script under the instance's operation lock.
  require("./lib/opLock").guardModOperation();
  main();
}
