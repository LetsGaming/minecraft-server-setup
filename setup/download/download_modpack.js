const axios = require("axios");
const path = require("path");
const { project_slug, version_id } = require("./modrinth_variables.json");
const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
} = require("./download_utils");

// Validate input
if (
  !project_slug ||
  !version_id ||
  project_slug === "none" ||
  version_id === "none"
) {
  console.error(
    'Error: project_slug or version_id is missing or set to "none". Please check modrinth_variables.json.'
  );
  process.exit(1);
}

createDownloadDir(path.join(__dirname, "temp"));

fetchModPackInfo();

function fetchModPackInfo() {
  axios
    .get(`https://api.modrinth.com/v2/version/${version_id}`)
    .then((response) => {
      const versionData = response.data;

      const serverFiles = versionData.files.filter(
        (f) =>
          f.filename.toLowerCase().includes("server") &&
          f.url &&
          f.filename.endsWith(".zip")
      );

      const serverFile = serverFiles[0] || versionData.files[0];

      if (!serverFile) {
        throw new Error("No server pack file found for the modpack.");
      }

      const gameVersion = versionData.game_versions[0] || "none";
      const modLoader = versionData.loaders?.[0] || "none";

      console.log(
        `Downloading server pack (${formatBytes(serverFile.size || 0)})...`
      );

      const outputPath = path.join(__dirname, "temp", "server-pack.zip");

      return downloadFile(
        serverFile.url,
        outputPath,
        serverFile.size || 0
      ).then(() => {
        saveDownloadedVersion(
          "modpack",
          project_slug,
          version_id,
          modLoader,
          gameVersion
        );
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
