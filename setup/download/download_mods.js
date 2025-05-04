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

if (!api_key || api_key === "none") {
  console.error(
    "Error: api_key is missing/invalid in curseforge_variables.json."
  );
  process.exit(0);
}

if (!Array.isArray(mod_ids) || mod_ids.length === 0) {
  console.error("No mod_ids provided in curseforge_variables.json.");
  process.exit(0);
}

const curseforgeAPIKey = api_key;
const validModIDs = mod_ids.filter((id) => id && id !== "none");
const modsDir = path.join(__dirname, "temp", "mods");
createDownloadDir(modsDir);

const targetMinecraftVersion = getMinecraftVersion();
const targetModLoader = getModLoader();

if (!targetMinecraftVersion || !targetModLoader) {
  console.error(
    "Missing Minecraft version or mod loader in downloaded_versions.json."
  );
  process.exit(1);
}

const processedMods = new Set();

(async () => {
  for (const modID of validModIDs) {
    console.log(`\nProcessing mod ID: ${modID}`);
    await downloadModAndDependencies(modID);
  }
})();

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

    // Match both Minecraft version and mod loader in gameVersions
    const compatibleFile = files.find(
      (file) =>
        file.gameVersions.includes(targetMinecraftVersion) &&
        file.gameVersions.some(
          (v) => v.toLowerCase() === targetModLoader.toLowerCase()
        )
    );

    if (!compatibleFile) {
      console.warn(
        `No compatible file for mod ID ${modID} with Minecraft ${targetMinecraftVersion} and ${targetModLoader}`
      );
      return;
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

    const outputPath = path.join(modsDir, fileName);
    console.log(
      `Downloading ${fileName} (${formatBytes(fileLength)}) to temp/mods...`
    );
    await downloadFile(downloadUrl, outputPath, fileLength);
    saveDownloadedVersion("mods", modID, fileID);

    // Recursively process required dependencies
    if (Array.isArray(dependencies)) {
      for (const dep of dependencies) {
        // RequiredDependency
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
