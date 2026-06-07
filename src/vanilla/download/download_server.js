// download_server.js
const axios  = require("axios");
const crypto = require("crypto");
const fs     = require("fs");
const path   = require("path");
const { spawn } = require("child_process");
const {
  getVersionInfo,
  getJavaVersionFor,
  saveGameVersion,
  saveModLoader,
} = require("../../setup/download/download_utils.js");
const { JAVA } = require("../../../variables.json");

const outputDir = path.resolve(__dirname, "..", "temp");
if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

/**
 * Verify a file's SHA-1 digest matches the expected value from Mojang's manifest.
 * Deletes the file and throws if the digest does not match, preventing a
 * silently corrupted or MITM-substituted server JAR from being launched.
 */
function verifyFileSha1(filePath, expectedSha1) {
  const hash = crypto.createHash("sha1");
  hash.update(fs.readFileSync(filePath));
  const actual = hash.digest("hex");
  if (actual !== expectedSha1) {
    fs.unlinkSync(filePath); // remove the corrupted/tampered file
    throw new Error(
      `SHA-1 mismatch for ${path.basename(filePath)}:\n` +
      `  expected: ${expectedSha1}\n` +
      `  actual:   ${actual}\n` +
      "The file may be corrupted or have been tampered with."
    );
  }
  console.log(`SHA-1 verified: ${path.basename(filePath)}`);
}

async function installMinecraftServer() {
  const config = JAVA.SERVER.VANILLA;
  const version = config.VERSION;
  const snapshot = config.SNAPSHOT;
  const useFabric = config.USE_FABRIC;

  try {
    const { versionId, metadataUrl } = await getVersionInfo(version, snapshot);
    if (useFabric) {
      saveInformation(versionId, "fabric");
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
  const meta        = await axios.get(metadataUrl);
  const serverInfo  = meta.data.downloads?.server;
  const serverUrl   = serverInfo?.url;
  const expectedSha = serverInfo?.sha1;

  if (!serverUrl) throw new Error(`No vanilla server jar for ${versionId}`);

  const jarPath = path.join(outputDir, "server.jar");
  const writer  = fs.createWriteStream(jarPath);
  const response = await axios.get(serverUrl, { responseType: "stream" });

  response.data.pipe(writer);
  await new Promise((res, rej) => {
    writer.on("finish", res);
    writer.on("error", rej);
  });

  // Verify the downloaded JAR against Mojang's manifest SHA-1.
  // This detects CDN corruption and MITM-substituted binaries.
  if (expectedSha) {
    verifyFileSha1(jarPath, expectedSha);
  } else {
    console.warn("[WARN] No SHA-1 in manifest for this version — skipping integrity check.");
  }

  console.log(`Vanilla server jar saved to ${jarPath}`);
  saveInformation(versionId, null);
}

function saveInformation(versionId, modLoader) {
  saveGameVersion(versionId);
  saveModLoader(modLoader);
  console.log(`Game version ${versionId} and mod loader ${modLoader} saved.`);
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

  // Get the Java version for the Minecraft version (async API lookup)
  const javaVersion = await getJavaVersionFor(versionId);

  // Find the corresponding Java binary from Jabba
  const jabbaDir = path.join(process.env.HOME, ".jabba", "jdk");
  const installed = fs
    .readdirSync(jabbaDir)
    .find((name) => name.includes(`@${javaVersion}.`));
  if (!installed) {
    throw new Error(
      `No installed Jabba candidate found for Java ${javaVersion}`
    );
  }

  const javaBin = path.join(jabbaDir, installed, "bin", "java");
  if (!fs.existsSync(javaBin)) {
    throw new Error(`Java binary not found at ${javaBin}`);
  }

  await new Promise((resolve, reject) => {
    const java = spawn(
      javaBin,
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
    await spawnModDownloader(modFile, modsDir, versionId);
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

async function spawnModDownloader(modsFilePath, modsDir, versionId) {
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
        `--modSlugsFile=${modsFilePath}`,
        `--downloadDir=${modsDir}`,
        `--mcVersion=${versionId}`,
        `--modLoader=fabric`,
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
