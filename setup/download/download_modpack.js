const path = require("path");
const { pack_id, api_key } = require("./json/curseforge_variables.json");
const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
} = require("./download_utils");

// Validate input
if (!pack_id || !api_key || pack_id === "none" || api_key === "none") {
  console.error(
    "Error: pack_id or api_key is missing or incorrect. Please check the 'curseforge_variables.json' file."
  );
  process.exit(1);
}

// Ensure temp directory exists
const tempDir = path.join(__dirname, "temp");
createDownloadDir(tempDir);

const outputPath = path.join(tempDir, "server-pack.zip");

const axios = require("axios");

(async () => {
  try {
    // 1. Fetch modpack files
    const filesResponse = await axios.get(
      `https://api.curseforge.com/v1/mods/${pack_id}/files`,
      {
        headers: { "x-api-key": api_key },
      }
    );

    const files = filesResponse.data.data;

    // 2. Filter for server pack .zip
    const serverFile = files.find(
      (f) =>
        f.fileName.toLowerCase().includes("server") && f.fileName.endsWith(".zip")
    );

    if (!serverFile) {
      throw new Error("No server pack file found for this modpack.");
    }

    const downloadUrl = serverFile.downloadUrl;
    const totalSize = serverFile.fileLength || 0;

    console.log(
      `Downloading server pack (${formatBytes(totalSize)})...`
    );

    // 3. Download using download_utils
    await downloadFile(downloadUrl, outputPath, totalSize);

    // 4. Save downloaded version info
    saveDownloadedVersion(
      "modpack",
      pack_id,
      serverFile.id,
      serverFile.modLoader || null,
      serverFile.gameVersion?.[0] || null
    );

    console.log("Server pack downloaded and version saved successfully!");
  } catch (err) {
    console.error("Error during modpack download process:", err.message);
    process.exit(1);
  }
})();
