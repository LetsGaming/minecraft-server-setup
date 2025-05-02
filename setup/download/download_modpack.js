const axios = require("axios");
const path = require("path");
const { pack_id, api_key } = require("./curseforge_variables.json");
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
  axios
    .get(`https://api.curseforge.com/v1/mods/${packID}`, {
      headers: { "x-api-key": curseforgeAPIKey },
    })
    .then((response) => {
      const mainFileId = response.data.data.mainFileId;
      return axios.get(
        `https://api.curseforge.com/v1/mods/${packID}/files/${mainFileId}`,
        {
          headers: { "x-api-key": curseforgeAPIKey },
        }
      );
    })
    .then((response) => {
      const serverPackFileId = response.data.data.serverPackFileId;
      return axios.get(
        `https://api.curseforge.com/v1/mods/${packID}/files/${serverPackFileId}`,
        {
          headers: { "x-api-key": curseforgeAPIKey },
        }
      );
    })
    .then((response) => {
      const fileData = response.data.data;
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
        saveDownloadedVersion("modpack", packID, fileData.id);
      });
    })
    .catch((err) => {
      console.error(
        "Error during modpack download process:",
        err.response?.data || err.message
      );
    });
}
