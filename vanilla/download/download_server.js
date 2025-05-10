// download_server.js
const axios = require("axios");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { getVersionInfo } = require("../../setup/download/download_utils.js");
const { JAVA } = require("../../variables.json");

const outputDir = path.resolve(__dirname, "..", "temp");
if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

async function installMinecraftServer() {
  const config = JAVA.SERVER.VANILLA;
  const version = config.VERSION;
  const snapshot = config.SNAPSHOT;
  const useFabric = config.USE_FABRIC;

  try {
    const { versionId, metadataUrl } = await getVersionInfo(version, snapshot);
    if (useFabric) {
      await installFabricServer(versionId);
      await installMods(versionId);
    } else {
      await installVanillaServer(versionId, metadataUrl);
    }
  } catch (err) {
    console.error("Server installation failed:", err.message);
    process.exit(1);
  }
}

async function installVanillaServer(versionId, metadataUrl) {
  console.log(`Downloading vanilla server for ${versionId}...`);
  const meta = await axios.get(metadataUrl);
  const serverUrl = meta.data.downloads?.server?.url;

  if (!serverUrl) throw new Error(`No vanilla server jar for ${versionId}`);

  const jarPath = path.join(outputDir, "server.jar");
  const writer = fs.createWriteStream(jarPath);
  const response = await axios.get(serverUrl, { responseType: "stream" });

  response.data.pipe(writer);
  await new Promise((res, rej) => {
    writer.on("finish", res);
    writer.on("error", rej);
  });

  console.log(`Vanilla server jar saved to ${jarPath}`);
}

async function installFabricServer(versionId) {
  console.log(`Installing Fabric server for ${versionId}...`);

  const installerInfo = await axios.get(
    "https://meta.fabricmc.net/v2/versions/installer"
  );
  const stableInstaller = installerInfo.data.find((i) => i.stable);
  if (!stableInstaller) throw new Error("No stable Fabric installer found");

  const installerVersion = stableInstaller.version;
  const installerJar = `fabric-installer-${installerVersion}.jar`;
  const installerPath = path.join(outputDir, installerJar);
  const url = `https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installerVersion}/${installerJar}`;

  await downloadFile(url, installerPath);

  await new Promise((resolve, reject) => {
    const java = spawn(
      "java",
      [
        "-jar",
        installerPath,
        "server",
        "-mcversion",
        versionId,
        "-downloadMinecraft",
      ],
      { cwd: outputDir, stdio: "inherit" }
    );

    java.on("exit", (code) => {
      fs.unlinkSync(installerPath);
      if (code === 0) {
        console.log("Fabric server installed successfully.");
        resolve();
      } else {
        reject(new Error(`Fabric installer failed (exit ${code})`));
      }
    });
  });
}

async function installMods(versionId) {
  const { PERFORMANCE_MODS, UTILITY_MODS, OPTIONAL_MODS } =
    JAVA.SERVER.VANILLA.MODS;
  const modsDir = path.join(outputDir, "mods");
  if (!fs.existsSync(modsDir)) fs.mkdirSync(modsDir, { recursive: true });

  const categories = [
    { flag: PERFORMANCE_MODS, name: "performance" },
    { flag: UTILITY_MODS, name: "utility" },
    { flag: OPTIONAL_MODS, name: "optional" },
  ];

  for (const { flag, name } of categories) {
    if (!flag) {
      console.log(`Skipping ${name} mods.`);
      continue;
    }

    const modFile = path.join(__dirname, `${name}_mods.txt`);
    if (!fs.existsSync(modFile)) {
      console.warn(`Missing ${modFile}, skipping.`);
      continue;
    }

    console.log(`Installing ${name} mods...`);
    await spawnModDownloader(modFile, modsDir);
  }
}

async function downloadFile(url, destPath) {
  const writer = fs.createWriteStream(destPath);
  const resp = await axios.get(url, { responseType: "stream" });
  resp.data.pipe(writer);

  return new Promise((res, rej) => {
    writer.on("finish", res);
    writer.on("error", rej);
  });
}

async function spawnModDownloader(modsFilePath, modsDir) {
  const modDownloader = path.resolve(
    __dirname,
    "..",
    "..",
    "setup",
    "download",
    "download_mods.js"
  );

  await new Promise((resolve, reject) => {
    const child = spawn(
      "node",
      [
        modDownloader,
        `--modIdsFile=${modsFilePath}`,
        `--downloadDir=${modsDir}`,
      ],
      { stdio: "inherit" }
    );

    child.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`Mod downloader failed with exit ${code}`));
    });
  });
}

installMinecraftServer();
