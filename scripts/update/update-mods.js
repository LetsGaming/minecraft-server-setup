const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const axios = require("axios");

// Read variables.txt and parse SERVER_PATH
const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
function loadVariables() {
  const content = fs.readFileSync(variablesPath, "utf8");
  const lines = content.split(/\r?\n/);

  const vars = {};
  for (const line of lines) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (match) {
      let value = match[2].trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      vars[match[1]] = value;
    }
  }
  return vars;
}

// Run check-updates.js with --json and return parsed JSON
function runCheckUpdates(version) {
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
          const data = JSON.parse(stdout);
          resolve(data);
        } catch {
          reject(
            new Error("Failed to parse JSON output from check-updates.js")
          );
        }
      }
    );
  });
}

// Download a file from url and save to filepath
async function downloadFile(url, filepath) {
  const writer = fs.createWriteStream(filepath);
  const response = await axios({
    url,
    method: "GET",
    responseType: "stream",
  });

  return new Promise((resolve, reject) => {
    response.data.pipe(writer);
    let error = null;
    writer.on("error", (err) => {
      error = err;
      writer.close();
      reject(err);
    });
    writer.on("close", () => {
      if (!error) resolve();
    });
  });
}

// ---------- robust outdated mod detection & removal ----------

function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function findOutdatedModFiles(existingFiles, modsDir, slug) {
  const slugLower = slug.toLowerCase();
  const slugEscaped = escapeRegex(slugLower);

  const modRegex = new RegExp(
    `^${slugEscaped}(?:[-_.]|$).+\\.jar$`,
    "i"
  );

  const candidates = [];

  for (const file of existingFiles) {
    if (!modRegex.test(file)) continue;

    const filePath = path.join(modsDir, file);
    let stat;

    try {
      stat = fs.lstatSync(filePath);
    } catch {
      console.warn(`Could not stat file: ${filePath}, skipping.`);
      continue;
    }

    if (!stat.isFile()) {
      console.warn(`Skipping non-file entry: ${filePath}`);
      continue;
    }

    if (stat.isSymbolicLink()) {
      console.warn(`Skipping symlink: ${filePath}`);
      continue;
    }

    candidates.push({
      file,
      filePath,
      mtime: stat.mtimeMs,
    });
  }

  if (candidates.length <= 1) return [];

  candidates.sort((a, b) => a.mtime - b.mtime);

  return candidates.slice(0, -1);
}

function removeOutdatedMods(existingFiles, modsDir, slug) {
  const outdated = findOutdatedModFiles(existingFiles, modsDir, slug);

  for (const { file, filePath } of outdated) {
    console.log(`Removing outdated mod: ${file}`);
    try {
      fs.unlinkSync(filePath);
    } catch (err) {
      console.error(`Failed to remove ${filePath}: ${err.message}`);
    }
  }
}

// ------------------------------------------------------------

async function main() {
  try {
    const vars = loadVariables();
    const serverPath = vars.SERVER_PATH;
    if (!fs.existsSync(serverPath)) {
      throw new Error(`SERVER_PATH does not exist: ${serverPath}`);
    }

    const modsDir = path.join(serverPath, "mods");
    if (!fs.existsSync(modsDir)) {
      console.log(`Mods directory does not exist, creating: ${modsDir}`);
      fs.mkdirSync(modsDir, { recursive: true });
    }

    const downloadedVersionsPath = path.resolve(
      __dirname,
      "..",
      "common",
      "downloaded_versions.json"
    );
    if (!fs.existsSync(downloadedVersionsPath)) {
      throw new Error("downloaded_versions.json not found.");
    }

    const downloadedVersions = JSON.parse(
      fs.readFileSync(downloadedVersionsPath, "utf8")
    );

    const version =
      process.argv[2] || downloadedVersions.gameVersion || "latest";

    console.log("Running check-updates.js to get update info...");
    const updateData = await runCheckUpdates(version);
    const { results } = updateData;

    for (const mod of results) {
      if (mod.status !== "update_available") {
        console.log(`Skipping mod '${mod.slug}': status=${mod.status}`);
        continue;
      }

      if (!mod.downloadUrl) {
        console.warn(`No download URL for mod '${mod.slug}', skipping.`);
        continue;
      }

      const existingFiles = fs.readdirSync(modsDir);
      removeOutdatedMods(existingFiles, modsDir, mod.slug);

      const urlPath = new URL(mod.downloadUrl).pathname;
      const encodedFilename = path.basename(urlPath);
      const filename = decodeURIComponent(encodedFilename);
      const targetPath = path.join(modsDir, filename);

      console.log(`Downloading latest version of mod '${mod.slug}'...`);
      await downloadFile(mod.downloadUrl, targetPath);
      console.log(`Downloaded and saved to ${targetPath}`);

      downloadedVersions.mods[mod.slug] = mod.latestVersionId;

      fs.writeFileSync(
        downloadedVersionsPath,
        JSON.stringify(downloadedVersions, null, 2),
        "utf8"
      );
      console.log(`Updated downloaded_versions.json for mod '${mod.slug}'`);
    }

    console.log("Mod updates completed.");
  } catch (err) {
    console.error("Error updating mods:", err.message);
    process.exit(1);
  }
}

main();
