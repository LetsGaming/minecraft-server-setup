const fs = require("fs");
const axios = require("axios");
const path = require("path");
const { mod_ids, api_key } = require("./curseforge_variables.json");
const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
  isAlreadyDownloaded,
  getMinecraftVersion,
  getModLoader,
} = require("./download_utils");

// === Argument Parsing ===
const args = process.argv.slice(2);
const downloadDirArg = args.find((arg) => arg.startsWith("--downloadDir="));
const modIdsFileArg = args.find((arg) => arg.startsWith("--modIdsFile="));

const customDownloadDir = downloadDirArg
  ? path.resolve(downloadDirArg.split("=")[1])
  : path.join(__dirname, "temp", "mods");

const modIdsFilePath = modIdsFileArg
  ? path.resolve(modIdsFileArg.split("=")[1])
  : null;

// === Setup ===
if (!api_key || api_key === "none") {
  console.error(
    "Error: api_key is missing/invalid in curseforge_variables.json."
  );
  process.exit(0);
}

// === Read mod IDs from file if provided ===
let validModIDs = [];

if (modIdsFilePath && fs.existsSync(modIdsFilePath)) {
  try {
    const raw = fs.readFileSync(modIdsFilePath, "utf8");
    validModIDs = raw
      .split(/\r?\n|,/)
      .map((id) => id.trim())
      .filter((id) => /^\d+$/.test(id)); // keep only numeric IDs

    if (validModIDs.length > 0) {
      console.log(
        `Using mod IDs from ${modIdsFilePath}: ${validModIDs.join(", ")}`
      );
    }
  } catch (err) {
    console.error(`Error reading mod ID file: ${err.message}`);
    process.exit(1);
  }
}

// === Fallback to JSON if no IDs loaded ===
if (validModIDs.length === 0) {
  if (Array.isArray(mod_ids) && mod_ids.length > 0) {
    validModIDs = mod_ids.filter((id) => id && id !== "none");
    console.log(
      `Using mod IDs from curseforge_variables.json: ${validModIDs.join(", ")}`
    );
  } else {
    console.error(
      "No mod IDs provided via --modIdsFile or curseforge_variables.json."
    );
    process.exit(1);
  }
}

const curseforgeAPIKey = api_key;
createDownloadDir(customDownloadDir);

const targetMinecraftVersion = getMinecraftVersion();
const targetModLoader = getModLoader();

if (!targetMinecraftVersion || !targetModLoader) {
  console.error(
    "Missing Minecraft version or mod loader in downloaded_versions.json."
  );
  process.exit(1);
}

const processedMods = new Set();

// === Main Loop ===
(async () => {
  for (const modID of validModIDs) {
    console.log(`\nProcessing mod ID: ${modID}`);
    await downloadModAndDependencies(modID);
  }
})();

// === Core Function ===
async function downloadModAndDependencies(modID) {
  if (processedMods.has(modID)) return;
  processedMods.add(modID);

  try {
    const filesResp = await axios.get(
      `https://api.curseforge.com/v1/mods/${modID}/files`,
      { headers: { "x-api-key": curseforgeAPIKey } }
    );

    const files = filesResp.data.data;
    if (!Array.isArray(files) || files.length === 0) {
      console.error(`No files found for mod ID ${modID}`);
      return;
    }

    const isCompatible = (file) =>
      file.gameVersions.includes(targetMinecraftVersion) &&
      file.gameVersions.some(
        (v) => v.toLowerCase() === targetModLoader.toLowerCase()
      );

    // Prefer release, fallback to newest compatible beta/alpha
    let compatibleFile = files.find(
      (file) => isCompatible(file) && file.releaseType === 1
    );

    if (!compatibleFile) {
      const compatibleAlternatives = files
        .filter(isCompatible)
        .sort((a, b) => new Date(b.fileDate) - new Date(a.fileDate)); // newest first

      if (compatibleAlternatives.length > 0) {
        compatibleFile = compatibleAlternatives[0];
        console.warn(
          `Warning: No release found for mod ID ${modID}. Using ${
            ["alpha", "beta", "release"][compatibleFile.releaseType - 1]
          } (${compatibleFile.fileDate}) instead.`
        );
      } else {
        console.warn(
          `No compatible file for mod ID ${modID} with Minecraft ${targetMinecraftVersion} and ${targetModLoader}`
        );
        return;
      }
    }

    const { id: fileID } = compatibleFile;

    if (isAlreadyDownloaded("mods", modID, fileID)) {
      console.log(
        `Mod ID ${modID} (file ${fileID}) already downloaded. Skipping.`
      );
      return;
    }

    const fileDetailsResp = await axios.get(
      `https://api.curseforge.com/v1/mods/${modID}/files/${fileID}`,
      { headers: { "x-api-key": curseforgeAPIKey } }
    );
    const fileData = fileDetailsResp.data.data;

    const { downloadUrl, fileName, fileLength, dependencies } = fileData;
    if (!downloadUrl) {
      console.error(`No download URL for mod ID ${modID}`);
      return;
    }

    const outputPath = path.join(customDownloadDir, fileName);
    console.log(
      `Downloading ${fileName} (${formatBytes(
        fileLength
      )}) to ${customDownloadDir}...`
    );
    await downloadFile(downloadUrl, outputPath, fileLength);
    saveDownloadedVersion("mods", modID, fileID);

    if (Array.isArray(dependencies)) {
      for (const dep of dependencies) {
        console.log(`→ Found dependency: ${dep.modId}`);
        await downloadModAndDependencies(dep.modId);
      }
    }
  } catch (err) {
    console.error(
      `Error processing mod ID ${modID}:`,
      err.response?.data || err.message
    );
  }
}
