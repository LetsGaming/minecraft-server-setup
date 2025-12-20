const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const axios = require("axios");

// ---------------- paths ----------------

const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "common",
  "downloaded_versions.json"
);

// ---------------- helpers ----------------

function loadVariables() {
  const content = fs.readFileSync(variablesPath, "utf8");
  const lines = content.split(/\r?\n/);

  const vars = {};
  for (const line of lines) {
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

function detectInstalledJar(modsDir, slug, excludeFilename) {
  const slugRegex = new RegExp(
    `(^|[-_.])${escapeRegex(slug)}([-.+_]|$).*\\.jar$`,
    "i"
  );

  return fs
    .readdirSync(modsDir)
    .filter((f) => f.endsWith(".jar"))
    .filter((f) => f !== excludeFilename)
    .map((file) => {
      const fullPath = path.join(modsDir, file);
      try {
        const stat = fs.lstatSync(fullPath);
        if (!stat.isFile() || stat.isSymbolicLink()) return null;
        return { file, fullPath };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .filter((e) => slugRegex.test(e.file));
}

// ---------------- migration ----------------

function migrateDownloadedVersions(downloadedVersions, modsDir) {
  let changed = false;

  for (const [slug, value] of Object.entries(downloadedVersions.mods)) {
    if (typeof value !== "string") continue;

    console.log(`Migrating legacy entry: ${slug}`);

    const matches = detectInstalledJar(modsDir, slug);

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
        `Ambiguous jars for ${slug}: ${matches.map((m) => m.file).join(", ")}`
      );
    }

    changed = true;
  }

  if (changed) {
    fs.writeFileSync(
      downloadedVersionsPath,
      JSON.stringify(downloadedVersions, null, 2),
      "utf8"
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
              `Failed to run check-updates.js: ${stderr || err.message}`
            )
          );
        }

        try {
          resolve(JSON.parse(stdout));
        } catch {
          reject(
            new Error("Failed to parse JSON output from check-updates.js")
          );
        }
      }
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

// ---------------- main ----------------

async function main() {
  try {
    const migrateOnly = process.argv.includes("--migrate");

    const vars = loadVariables();
    const serverPath = vars.SERVER_PATH;
    if (!serverPath || !fs.existsSync(serverPath)) {
      throw new Error(`Invalid SERVER_PATH: ${serverPath}`);
    }

    const modsDir = path.join(serverPath, "mods");
    fs.mkdirSync(modsDir, { recursive: true });

    const downloadedVersions = JSON.parse(
      fs.readFileSync(downloadedVersionsPath, "utf8")
    );

    downloadedVersions.mods ??= {};

    if (migrateOnly) {
      migrateDownloadedVersions(downloadedVersions, modsDir);
      return;
    }

    const version =
      process.argv[2] || downloadedVersions.gameVersion || "latest";

    const { results } = await runCheckUpdates(version);

    for (const mod of results) {
      if (mod.status !== "update_available") {
        console.log(`No update available for: ${mod.slug}\n`);
        continue;
      }

      if (!mod.downloadUrl) continue;

      const filename = decodeURIComponent(
        path.basename(new URL(mod.downloadUrl).pathname)
      );

      const targetPath = path.join(modsDir, filename);
      const tempPath = `${targetPath}.tmp`;

      console.log(
        `Updating mod: ${mod.slug} to version ${mod.latestVersionId}`
      );

      await downloadFile(mod.downloadUrl, tempPath);

      const previous = downloadedVersions.mods[mod.slug];
      if (previous?.filename) {
        safeUnlink(path.join(modsDir, previous.filename));
      } else {
        const installedJars = detectInstalledJar(modsDir, mod.slug, filename);
        for (const jar of installedJars) {
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
        "utf8"
      );
      console.log(`Downloaded and installed: ${filename}\n`);
    }

    console.log("Mod updates completed.");
  } catch (err) {
    console.error("Error:", err.message);
    process.exit(1);
  }
}

main();
