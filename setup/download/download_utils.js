const fs = require("fs");
const path = require("path");
const axios = require("axios");
const semver = require("semver");

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

function getDownloadedVersions() {
  const versionFile = path.resolve(
    __dirname,
    "..",
    "..",
    "scripts",
    "common",
    "downloaded_versions.json"
  );
  if (!fs.existsSync(versionFile)) return null;

  let downloadedVersions = {};
  try {
    downloadedVersions = JSON.parse(fs.readFileSync(versionFile, "utf-8"));
  } catch (err) {
    console.warn(
      "Warning: Could not parse downloaded_versions.json. Assuming no mods are downloaded."
    );
    return null;
  }
  return downloadedVersions;
}

function saveDownloadedVersion(
  type,
  modId,
  fileId,
  modLoader = null,
  gameVersion = null
) {
  const versionFile = path.resolve(
    __dirname,
    "..",
    "..",
    "scripts",
    "common",
    "downloaded_versions.json"
  );

  let existing = {};
  if (fs.existsSync(versionFile)) {
    try {
      existing = JSON.parse(fs.readFileSync(versionFile, "utf-8"));
    } catch (err) {
      console.warn(
        "Warning: Could not parse downloaded_versions.json. Overwriting..."
      );
    }
  }

  // Set modLoader and gameVersion if provided
  if (modLoader) existing.modLoader = modLoader;
  if (gameVersion) existing.gameVersion = gameVersion;

  // Ensure 'modpack' and 'mods' objects exist
  if (!existing.modpack) existing.modpack = {};
  if (!existing.mods) existing.mods = {};

  // Only allow 'modpack' or 'mods' as valid types
  if (type !== "modpack" && type !== "mods") {
    console.warn(`Warning: Unknown type '${type}' provided. Skipping.`);
    return;
  }

  existing[type][modId] = fileId;

  // Write back to file
  fs.writeFileSync(versionFile, JSON.stringify(existing, null, 2), "utf-8");
}

const saveGameVersion = (gameVersion) => {
  const versionFile = path.resolve(
    __dirname,
    "..",
    "..",
    "scripts",
    "common",
    "downloaded_versions.json"
  );
  let existing = {};
  if (fs.existsSync(versionFile)) {
    try {
      existing = JSON.parse(fs.readFileSync(versionFile, "utf-8"));
    } catch (err) {
      console.warn(
        "Warning: Could not parse downloaded_versions.json. Overwriting..."
      );
    }
  }
  existing.gameVersion = gameVersion;
  fs.writeFileSync(versionFile, JSON.stringify(existing, null, 2), "utf-8");
};

const saveModLoader = (modLoader) => {
  const versionFile = path.resolve(
    __dirname,
    "..",
    "..",
    "scripts",
    "common",
    "downloaded_versions.json"
  );
  let existing = {};
  if (fs.existsSync(versionFile)) {
    try {
      existing = JSON.parse(fs.readFileSync(versionFile, "utf-8"));
    } catch (err) {
      console.warn(
        "Warning: Could not parse downloaded_versions.json. Overwriting..."
      );
    }
  }
  existing.modLoader = modLoader;
  fs.writeFileSync(versionFile, JSON.stringify(existing, null, 2), "utf-8");
};

const MINECRAFT_JAVA_MAP = [
  { mc: "1.21", java: "24" },
  { mc: "1.20", java: "21" },
  { mc: "1.18", java: "17" },
  { mc: "1.17", java: "16" },
  { mc: "1.16", java: "8" },
  { mc: "1.12", java: "8" },
];

function getJavaVersionFor(mcVersion) {
  if (mcVersion === "latest") {
    mcVersion = MINECRAFT_JAVA_MAP[0].mc;
  }
  const sorted = MINECRAFT_JAVA_MAP.sort((a, b) =>
    semver.rcompare(semver.coerce(a.mc), semver.coerce(b.mc))
  );
  for (const entry of sorted) {
    if (semver.gte(semver.coerce(mcVersion), semver.coerce(entry.mc))) {
      return entry.java;
    }
  }
  throw new Error(`Unsupported Minecraft version: ${mcVersion}`);
}

async function getVersionInfo(requestedVersion, allowSnapshot) {
  const manifestUrl =
    "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
  const manifestResp = await axios.get(manifestUrl);
  const manifest = manifestResp.data;

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

async function getMinecraftVersion() {
  const downloadedVersions = getDownloadedVersions();
  if (!downloadedVersions) {
    // No Modpack downloaded
    const { JAVA } = require("../../variables.json");
    const VERSION = JAVA.SERVER.VANILLA.VERSION;
    if (VERSION == "latest") {
      const { versionId } = await getVersionInfo(
        "latest",
        JAVA.SERVER.VANILLA.SNAPSHOT
      );
      return versionId;
    }
  }

  return downloadedVersions?.gameVersion || null;
}

function getModLoader() {
  const downloadedVersions = getDownloadedVersions();
  if (!downloadedVersions) {
    // No Modpack downloaded
    const { JAVA } = require("../../variables.json");
    return JAVA.SERVER.VANILLA.USE_FABRIC ? "fabric" : null;
  }

  return downloadedVersions?.modLoader || null;
}

function isAlreadyDownloaded(type, modID, fileID) {
  const downloadedVersions = getDownloadedVersions();
  if (!downloadedVersions) return false;
  return downloadedVersions?.[type]?.[modID] === fileID;
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
};
