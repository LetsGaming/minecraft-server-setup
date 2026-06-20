const axios = require("axios");
const path = require("path");
const { loadVariablesJson } = require("./json/load");
const { pack_id, api_key } = loadVariablesJson("curseforge_variables");
const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
} = require("./download_utils");

// Validate input
if (!pack_id || !api_key || pack_id === "none" || api_key === "none") {
  console.error(
    'Error: pack_id or api_key is missing or set to "none". Please check curseforge_variables.json.'
  );
  process.exit(1);
}

const packID = pack_id;
const curseforgeAPIKey = api_key;

createDownloadDir(path.join(__dirname, "temp"));

fetchModPackInfo();

function fetchModPackInfo() {
  // Fetching modpack info from CurseForge API
  axios
    .get(`https://api.curseforge.com/v1/mods/${packID}`, {
      headers: { "x-api-key": curseforgeAPIKey },
    })
    .then((response) => {
      const mainFileId = response.data.data.mainFileId;
      if (!mainFileId) {
        throw new Error("No main file ID found for the modpack.");
      }
      // Fetching the main file info
      return axios.get(
        `https://api.curseforge.com/v1/mods/${packID}/files/${mainFileId}`,
        {
          headers: { "x-api-key": curseforgeAPIKey },
        }
      );
    })
    .then((response) => {
      const serverPackFileId = response.data.data.serverPackFileId;
      if (!serverPackFileId) {
        throw new Error("No server pack file ID found for the modpack.");
      }
      // Fetching the server pack file info
      return axios.get(
        `https://api.curseforge.com/v1/mods/${packID}/files/${serverPackFileId}`,
        {
          headers: { "x-api-key": curseforgeAPIKey },
        }
      );
    })
    .then((response) => {
      if (!response.data.data) {
        throw new Error("No data found for the server pack file.");
      }
      const fileData = response.data.data;
      const gameVersions = fileData.gameVersions || [];

      // CurseForge does not guarantee the order of gameVersions, so the old
      // gameVersions[0]/[1] positional read was brittle. Detect the loader by
      // matching known loader names and pick the MC version by pattern
      // (legacy "1.x.y" or the new "YY.D[.H]" form).
      const KNOWN_LOADERS = ["forge", "fabric", "quilt", "neoforge"];
      const modLoader =
        gameVersions.find((v) =>
          KNOWN_LOADERS.includes(String(v).toLowerCase()),
        ) || "none";
      const gameVersion =
        gameVersions.find((v) => /^\d+(\.\d+){1,3}$/.test(String(v))) || "none";

      console.log(
        `Downloading server pack (${formatBytes(fileData.fileLength)})...`
      );
      const outputPath = path.join(__dirname, "temp", "server-pack.zip");

      return downloadFile(
        fileData.downloadUrl,
        outputPath,
        fileData.fileLength
      ).then(() => {
        // Save downloaded version info
        saveDownloadedVersion("modpack", packID, fileData.id, modLoader, gameVersion);
      });
    })
    .catch((err) => {
      console.error(
        "Error during modpack download process:",
        err.response?.data || err.message
      );
      process.exit(1);
    });
}