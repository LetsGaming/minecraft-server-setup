const axios = require("axios");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { JAVA } = require("../../variables.json");

const outputDir = path.resolve(__dirname, "server");

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

async function installMinecraftServer() {
  const VANILLA_CONFIG = JAVA.SERVER.VANILLA;

  const requestedVersion = VANILLA_CONFIG.VERSION;
  const allowSnapshot = VANILLA_CONFIG.SNAPSHOT;
  const useFabric = VANILLA_CONFIG.USE_FABRIC;

  try {
    const { versionId, metadataUrl } = await getVersionInfo(requestedVersion, allowSnapshot);

    if (useFabric) {
      await installFabricServer(versionId);
      // TODO: Add logic to install Fabric performance mods
    } else {
      await installVanillaServer(versionId, metadataUrl);
    }
  } catch (error) {
    console.error("Failed to install server:", error.message);
  }
}

async function installVanillaServer(versionId, metadataUrl) {
  const versionMetaResp = await axios.get(metadataUrl);
  const serverUrl = versionMetaResp.data.downloads.server?.url;

  if (!serverUrl) {
    throw new Error(`No server download available for version ${versionId}`);
  }

  const jarPath = path.join(outputDir, `server.jar`);
  const writer = fs.createWriteStream(jarPath);
  const serverJarResp = await axios.get(serverUrl, {
    responseType: "stream",
  });

  serverJarResp.data.pipe(writer);

  await new Promise((resolve, reject) => {
    writer.on("finish", resolve);
    writer.on("error", reject);
  });

  console.log(`Downloaded vanilla Minecraft server ${versionId} to ${jarPath}`);
}

async function installFabricServer(versionId) {
  const installerUrl = "https://meta.fabricmc.net/v2/versions/installer";

  // Get latest Fabric installer
  const installerResp = await axios.get(installerUrl);
  const installer = installerResp.data.find((entry) => entry.stable);
  if (!installer) throw new Error("No stable Fabric installer found.");

  const installerVersion = installer.version;
  const installerJar = `fabric-installer-${versionId}.jar`;
  const installerPath = path.join(outputDir, installerJar);
  const jarPath = path.join(outputDir, `fabric-server-launch.jar`);

  // Download the Fabric installer jar
  const installerDownloadUrl = `https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installerVersion}/fabric-installer-${installerVersion}.jar`;
  const writer = fs.createWriteStream(installerPath);
  const downloadResp = await axios.get(installerDownloadUrl, {
    responseType: "stream",
  });

  downloadResp.data.pipe(writer);
  await new Promise((resolve, reject) => {
    writer.on("finish", resolve);
    writer.on("error", reject);
  });

  // Run the Fabric installer with `--installServer`
  await new Promise((resolve, reject) => {
    const java = spawn("java", [
      "-jar",
      installerPath,
      "server",
      "-mcversion",
      versionId,
      "-downloadMinecraft"
    ], { stdio: "inherit" });

    java.on("exit", (code) => {
      if (code === 0) {
        console.log(`Fabric server ${versionId} installed in ${outputDir}`);
        fs.unlinkSync(installerPath); // Clean up the installer jar
        resolve();
      } else {
        reject(new Error(`Fabric installer exited with code ${code}`));
      }
    });
  });
}

module.exports = {
  installMinecraftServer,
};
