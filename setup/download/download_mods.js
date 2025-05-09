const fs = require("fs");
const path = require("path");
const axios = require("axios");
const {
  mod_ids,
  api_key: curseforgeAPIKey,
} = require("./curseforge_variables.json");

const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
  isAlreadyDownloaded,
  getMinecraftVersion,
  getModLoader,
} = require("./download_utils");

// ==== Config & Argument Parsing ====
const args = process.argv.slice(2);
const customDownloadDir = getDownloadDirFromArgs(args);
const modIds = getModIdsFromArgs(args) || getModIdsFromJson();

validateSetup(curseforgeAPIKey, modIds);
createDownloadDir(customDownloadDir);

let processedMods = new Set();

// ==== Main Entrypoint ====
(async () => {
  const minecraftVersion = await getMinecraftVersion();
  const modLoader = getModLoader();

  if (!minecraftVersion) {
    console.error(
      "Minecraft version not found. Please download a modpack first."
    );
    process.exit(1);
  }

  if (!modLoader) {
    console.error("Mod loader not found. Please download a modpack first.");
    process.exit(1);
  }

  for (const modID of modIds) {
    console.log(`\nProcessing mod ID: ${modID}`);
    await downloadModAndDependencies(modID, minecraftVersion, modLoader);
  }
})();

// ==== Argument Helpers ====

function getDownloadDirFromArgs(args) {
  const arg = args.find((a) => a.startsWith("--downloadDir="));
  return arg
    ? path.resolve(arg.split("=")[1])
    : path.join(__dirname, "temp", "mods");
}

function getModIdsFromArgs(args) {
  const fileArg = args.find((a) => a.startsWith("--modIdsFile="));
  if (!fileArg) return null;

  const filePath = path.resolve(fileArg.split("=")[1]);
  if (!fs.existsSync(filePath)) {
    console.error(`Mod IDs file not found: ${filePath}`);
    process.exit(1);
  }

  try {
    const content = fs.readFileSync(filePath, "utf8");
    const ids = content
      .split(/\r?\n|,/)
      .map((id) => id.trim())
      .filter((id) => /^\d+$/.test(id));
    if (ids.length) {
      console.log(`Using mod IDs from ${filePath}: ${ids.join(", ")}`);
      return ids;
    }
  } catch (err) {
    console.error(`Failed to read mod IDs file: ${err.message}`);
    process.exit(1);
  }

  return null;
}

function getModIdsFromJson() {
  if (Array.isArray(mod_ids) && mod_ids.length > 0) {
    const ids = mod_ids.filter((id) => id && id !== "none");
    console.log(
      `Using mod IDs from curseforge_variables.json: ${ids.join(", ")}`
    );
    return ids;
  }

  console.error("No mod IDs provided via args or JSON.");
  process.exit(1);
}

// ==== Validation ====

function validateSetup(apiKey, ids) {
  if (!apiKey || apiKey === "none") {
    console.error("Missing or invalid API key in curseforge_variables.json.");
    process.exit(1);
  }

  if (!Array.isArray(ids) || ids.length === 0) {
    console.error("No valid mod IDs found.");
    process.exit(1);
  }
}

// ==== Core Download Logic ====

async function downloadModAndDependencies(modID, mcVersion, modLoader) {
  if (processedMods.has(modID)) return;
  processedMods.add(modID);

  try {
    const files = await fetchModFiles(modID);
    const compatibleFile = selectCompatibleFile(files, mcVersion, modLoader);

    if (!compatibleFile) {
      console.warn(
        `No compatible file for mod ID ${modID} (MC ${mcVersion}, ${modLoader})`
      );
      return;
    }

    const fileID = compatibleFile.id;
    if (isAlreadyDownloaded("mods", modID, fileID)) {
      console.log(
        `Mod ID ${modID} (file ${fileID}) already downloaded. Skipping.`
      );
      return;
    }

    const fileDetails = await fetchFileDetails(modID, fileID);
    await downloadAndSaveFile(fileDetails, modID, fileID);

    // Recursively download dependencies
    if (Array.isArray(fileDetails.dependencies)) {
      for (const dep of fileDetails.dependencies) {
        console.log(`→ Found dependency: ${dep.modId}`);
        await downloadModAndDependencies(dep.modId, mcVersion, modLoader);
      }
    }
  } catch (err) {
    console.error(
      `Error processing mod ID ${modID}:`,
      err.response?.data || err.message
    );
  }
}

async function fetchModFiles(modID) {
  const response = await axios.get(
    `https://api.curseforge.com/v1/mods/${modID}/files`,
    {
      headers: { "x-api-key": curseforgeAPIKey },
    }
  );
  return response.data.data || [];
}

function selectCompatibleFile(files, mcVersion, modLoader) {
  const isCompatible = (file) =>
    file.gameVersions.includes(mcVersion) &&
    file.gameVersions.some((v) => v.toLowerCase() === modLoader.toLowerCase());

  let releaseFile = files.find(
    (file) => isCompatible(file) && file.releaseType === 1
  );
  if (releaseFile) return releaseFile;

  const fallback = files
    .filter(isCompatible)
    .sort((a, b) => new Date(b.fileDate) - new Date(a.fileDate));

  if (fallback.length) {
    const alt = fallback[0];
    console.warn(
      `No release found for mod ID ${alt.modId}. Using ${
        ["alpha", "beta", "release"][alt.releaseType - 1]
      } (${alt.fileDate}) instead.`
    );
    return alt;
  }

  return null;
}

async function fetchFileDetails(modID, fileID) {
  const resp = await axios.get(
    `https://api.curseforge.com/v1/mods/${modID}/files/${fileID}`,
    { headers: { "x-api-key": curseforgeAPIKey } }
  );
  return resp.data.data;
}

async function downloadAndSaveFile(fileData, modID, fileID) {
  const { downloadUrl, fileName, fileLength } = fileData;

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
}
