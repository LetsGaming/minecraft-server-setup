const fs = require("fs");
const path = require("path");
const axios = require("axios");

const MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

function createDownloadDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function formatTime(seconds) {
  const minutes = Math.floor(seconds / 60);
  seconds = Math.floor(seconds % 60);
  return `${minutes}m ${seconds}s`;
}

function formatBytes(bytes, decimals = 2) {
  if (!+bytes) return "0 Bytes";
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ["Bytes", "KiB", "MiB", "GiB", "TiB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`;
}

function downloadFile(url, fileName, totalSize) {
  return new Promise((resolve, reject) => {
    axios
      .get(url, { responseType: "stream" })
      .then((response) => {
        const writer = fs.createWriteStream(fileName);
        let downloaded = 0;
        let lastProgress = 0;
        const startTime = Date.now();

        response.data.pipe(writer);

        response.data.on("data", (chunk) => {
          downloaded += chunk.length;
          if (totalSize) {
            const progress = ((downloaded / totalSize) * 100).toFixed(2);

            if (progress >= lastProgress + 1) {
              const elapsed = (Date.now() - startTime) / 1000;
              const speed = downloaded / elapsed;
              const eta = (totalSize - downloaded) / speed;
              process.stdout.write(
                `Downloading... ${progress}% | Remaining: ${formatTime(eta)}\r`
              );
              lastProgress = Math.floor(progress);
            }
          }
        });

        writer.on("finish", () => {
          console.log("\nDownload complete!");
          resolve();
        });

        writer.on("error", (err) => {
          console.error("Error writing file:", err);
          reject(err);
        });
      })
      .catch((err) => {
        console.error("Download error:", err.response?.data || err.message);
        reject(err);
      });
  });
}

// ===== Version tracking =====

const VERSIONS_FILE_PATH = path.resolve(
  __dirname, "..", "..", "scripts", "common", "downloaded_versions.json"
);

function getDownloadedVersions() {
  if (!fs.existsSync(VERSIONS_FILE_PATH)) return null;

  try {
    return JSON.parse(fs.readFileSync(VERSIONS_FILE_PATH, "utf-8"));
  } catch (err) {
    console.warn(
      "Warning: Could not parse downloaded_versions.json. Assuming no mods are downloaded."
    );
    return null;
  }
}

function readVersionsFile() {
  if (!fs.existsSync(VERSIONS_FILE_PATH)) return {};
  try {
    return JSON.parse(fs.readFileSync(VERSIONS_FILE_PATH, "utf-8"));
  } catch {
    console.warn("Warning: Could not parse downloaded_versions.json. Overwriting...");
    return {};
  }
}

function writeVersionsFile(data) {
  const dir = path.dirname(VERSIONS_FILE_PATH);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(VERSIONS_FILE_PATH, JSON.stringify(data, null, 2), "utf-8");
}

function saveDownloadedVersion(type, modId, fileId, modLoader = null, gameVersion = null) {
  const existing = readVersionsFile();

  if (modLoader) existing.modLoader = modLoader;
  if (gameVersion) existing.gameVersion = gameVersion;

  if (!existing.modpack) existing.modpack = {};
  if (!existing.mods) existing.mods = {};

  if (type !== "modpack" && type !== "mods") {
    console.warn(`Warning: Unknown type '${type}' provided. Skipping.`);
    return;
  }

  existing[type][modId] = fileId;
  writeVersionsFile(existing);
}

function saveGameVersion(gameVersion) {
  const existing = readVersionsFile();
  existing.gameVersion = gameVersion;
  writeVersionsFile(existing);
}

function saveModLoader(modLoader) {
  const existing = readVersionsFile();
  existing.modLoader = modLoader;
  writeVersionsFile(existing);
}

function isAlreadyDownloaded(type, modID, fileID) {
  const downloadedVersions = getDownloadedVersions();
  if (!downloadedVersions) return false;
  return downloadedVersions?.[type]?.[modID] === fileID;
}

// ===== Mojang Version Manifest =====

let _manifestCache = null;

async function fetchManifest() {
  if (_manifestCache) return _manifestCache;
  const resp = await axios.get(MANIFEST_URL);
  _manifestCache = resp.data;
  return _manifestCache;
}

/**
 * Resolve a version string ("latest", "26.1", "1.21.4", etc.) to its
 * version ID and metadata URL from Mojang's version manifest.
 */
async function getVersionInfo(requestedVersion, allowSnapshot = false) {
  const manifest = await fetchManifest();

  let versionId = requestedVersion;

  if (requestedVersion === "latest") {
    versionId = allowSnapshot
      ? manifest.latest.snapshot
      : manifest.latest.release;
  }

  const versionData = manifest.versions.find((v) => v.id === versionId);

  if (!versionData) {
    throw new Error(`Version ${versionId} not found in version manifest.`);
  }

  return { versionId, metadataUrl: versionData.url };
}

/**
 * Dynamically determine the required Java major version for a given
 * Minecraft version by querying the version's metadata from Mojang's API.
 *
 * This replaces the old hardcoded MINECRAFT_JAVA_MAP and works with both
 * the legacy 1.x.y format and the new YY.D.H format (26.1, 26.2, etc.).
 */
async function getJavaVersionFor(mcVersion) {
  const { metadataUrl } = await getVersionInfo(mcVersion);
  const metaResp = await axios.get(metadataUrl);
  const meta = metaResp.data;

  if (meta.javaVersion && meta.javaVersion.majorVersion) {
    return String(meta.javaVersion.majorVersion);
  }

  // Fallback for very old versions that don't have javaVersion in metadata
  console.warn(
    `No javaVersion field in metadata for ${mcVersion}. Falling back to Java 8.`
  );
  return "8";
}

// ===== Minecraft version resolution helpers =====

async function getMinecraftVersion() {
  const downloadedVersions = getDownloadedVersions();
  if (!downloadedVersions) {
    const { JAVA } = require("../../variables.json");
    const VERSION = JAVA.SERVER.VANILLA.VERSION;
    if (VERSION === "latest") {
      const { versionId } = await getVersionInfo(
        "latest",
        JAVA.SERVER.VANILLA.SNAPSHOT
      );
      return versionId;
    }
    return VERSION;
  }

  return downloadedVersions?.gameVersion || null;
}

function getModLoader() {
  const downloadedVersions = getDownloadedVersions();
  if (!downloadedVersions) {
    const { JAVA } = require("../../variables.json");
    return JAVA.SERVER.VANILLA.USE_FABRIC ? "fabric" : null;
  }

  return downloadedVersions?.modLoader || null;
}

module.exports = {
  createDownloadDir,
  formatTime,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
  isAlreadyDownloaded,
  getMinecraftVersion,
  getModLoader,
  getVersionInfo,
  getJavaVersionFor,
  saveGameVersion,
  saveModLoader,
  fetchManifest,
};
