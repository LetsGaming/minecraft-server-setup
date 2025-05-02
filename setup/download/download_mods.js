const axios = require("axios");
const path = require("path");
const { mod_ids, api_key } = require("./curseforge_variables.json");
const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
} = require("./download_utils");

// Validate input
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

if (validModIDs.length === 0) {
  console.log("No valid mod_ids to process. Exiting.");
  process.exit(0);
}

// Ensure mods_temp folder exists
const modsDir = path.join(__dirname, "temp", "mods");
createDownloadDir(modsDir);

(async () => {
  for (const modID of validModIDs) {
    console.log(`\nProcessing mod ID: ${modID}`);
    await downloadLatestModFile(modID);
  }
})();

async function downloadLatestModFile(modID) {
  try {
    const modResponse = await axios.get(
      `https://api.curseforge.com/v1/mods/${modID}`,
      {
        headers: { "x-api-key": curseforgeAPIKey },
      }
    );

    const latestFileId = modResponse.data.data.latestFilesIndexes?.[0]?.fileId;
    if (!latestFileId) {
      console.error(`Could not find a latest file for mod ID ${modID}`);
      return;
    }

    const fileResponse = await axios.get(
      `https://api.curseforge.com/v1/mods/${modID}/files/${latestFileId}`,
      {
        headers: { "x-api-key": curseforgeAPIKey },
      }
    );

    const fileData = fileResponse.data.data;
    const { downloadUrl, fileName, fileLength } = fileData;

    if (!downloadUrl) {
      console.error(`No download URL for mod ID ${modID}`);
      return;
    }

    const outputPath = path.join(modsDir, fileName);

    console.log(
      `Downloading ${fileName} (${formatBytes(fileLength)}) to temp/mods...`
    );
    await downloadFile(downloadUrl, outputPath, fileLength).then(() => {
      // Save downloaded version info
      saveDownloadedVersion("mod", modID, fileData);
    });
  } catch (err) {
    console.error(
      `Error processing mod ID ${modID}:`,
      err.response?.data || err.message
    );
  }
}
