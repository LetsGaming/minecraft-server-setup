const axios = require("axios");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { getVersionInfo } = require("../../setup/download/download_utils.js");
const { JAVA } = require("../../variables.json");

const outputDir = path.resolve(__dirname, "..", "temp");
if (!fs.existsSync(outputDir)) {
  fs.mkdirSync(outputDir, { recursive: true });
}

async function installMinecraftServer() {
  const VANILLA_CONFIG = JAVA.SERVER.VANILLA;
  const requestedVersion = VANILLA_CONFIG.VERSION;
  const allowSnapshot = VANILLA_CONFIG.SNAPSHOT;
  const useFabric = VANILLA_CONFIG.USE_FABRIC;

  try {
    const { versionId, metadataUrl } = await getVersionInfo(
      requestedVersion,
      allowSnapshot
    );

    if (useFabric) {
      await installFabricServer(versionId);
      await installMods();
    } else {
      await installVanillaServer(versionId, metadataUrl);
    }
  } catch (error) {
    console.error("Failed to install server:", error.message);
  }
}

async function installVanillaServer(versionId, metadataUrl) {
  console.log(`Installing vanilla Minecraft server ${versionId}...`);
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
  console.log(`Installing Fabric server ${versionId}...`);
  const installerUrl = "https://meta.fabricmc.net/v2/versions/installer";
  const installerResp = await axios.get(installerUrl);
  const installer = installerResp.data.find((entry) => entry.stable);
  if (!installer) throw new Error("No stable Fabric installer found.");

  const installerVersion = installer.version;
  const installerJarName = `fabric-installer-${installerVersion}.jar`;
  const installerPath = path.join(outputDir, installerJarName);
  const jarPath = path.join(outputDir, "fabric-server-launch.jar");

  const installerDownloadUrl = `https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installerVersion}/${installerJarName}`;
  const writer = fs.createWriteStream(installerPath);
  const downloadResp = await axios.get(installerDownloadUrl, {
    responseType: "stream",
  });

  downloadResp.data.pipe(writer);
  await new Promise((resolve, reject) => {
    writer.on("finish", resolve);
    writer.on("error", reject);
  });

  const jabbaShPath = path.join(process.env.HOME, ".jabba", "jabba.sh");

  await new Promise((resolve, reject) => {
    const java = spawn(
      "/bin/bash",
      [
        "-c",
        `source ${jabbaShPath} && java -jar ${installerPath} server -mcversion ${versionId} -downloadMinecraft`,
      ],
      { cwd: outputDir, stdio: "inherit" }
    );

    java.on("exit", (code) => {
      if (code === 0) {
        console.log(`Fabric server ${versionId} installed in ${outputDir}`);
        fs.unlinkSync(installerPath);

        const generatedJar = path.join(outputDir, "server.jar");
        if (fs.existsSync(generatedJar)) {
          fs.renameSync(generatedJar, jarPath);
          console.log(`Renamed server.jar to ${path.basename(jarPath)}`);
        } else {
          console.warn(`Expected server.jar not found in ${outputDir}`);
        }

        resolve();
      } else {
        reject(new Error(`Fabric installer exited with code ${code}`));
      }
    });
  });
}

async function installMods() {
  const { PERFORMANCE_MODS, UTILITY_MODS, OPTIONAL_MODS } =
    JAVA.SERVER.VANILLA.MODS;

  const modGroups = [
    { name: "performance", file: PERFORMANCE_MODS },
    { name: "utility", file: UTILITY_MODS },
    { name: "optional", file: OPTIONAL_MODS },
  ];

  const modsToInstall = modGroups.filter((group) => group.file);

  if (modsToInstall.length === 0) {
    console.log("No mods specified for download.");
    return;
  }

  console.log(`Not all mods are guaranteed to be available for ${versionId}.`);

  for (const { name, file } of modsToInstall) {
    const filePath = path.join(__dirname, `${name}_mods.txt`);
    console.log(`Downloading ${name} mods...`);
    await downloadFabricMods(filePath);
  }
}

async function downloadFabricMods(modsFilePath) {
  const downloadModsPath = path.resolve(
    __dirname,
    "..",
    "..",
    "setup",
    "download",
    "download_mods.js"
  );

  console.log(`Starting mod download from ${modsFilePath}...`);

  await new Promise((resolve, reject) => {
    const child = spawn(
      "node",
      [
        downloadModsPath,
        `--modIdsFile=${modsFilePath}`,
        `--downloadDir=${path.join(outputDir, "mods")}`,
      ],
      {
        stdio: ["inherit", "pipe", "pipe"],
      }
    );

    child.stdout.on("data", (data) => {
      process.stdout.write(data);
    });

    child.stderr.on("data", (data) => {
      process.stderr.write(data);
    });

    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Child process exited with code ${code}`));
      }
    });
  });
}

(async () => {
  try {
    await installMinecraftServer();
  } catch (error) {
    console.error("Error during installation:", error.message);
  }
})();
