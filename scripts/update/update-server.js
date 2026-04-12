const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { spawn, execFile } = require("child_process");

// Import shared utilities instead of duplicating them
const downloadUtilsPath = path.resolve(__dirname, "../../setup/download/download_utils");
const {
  getVersionInfo,
  getJavaVersionFor,
  saveGameVersion,
  saveModLoader,
} = require(downloadUtilsPath);

const axios = require("axios");

const updateModsScript = path.resolve(__dirname, "update-mods.js");
const checkUpdatesScript = path.resolve(__dirname, "check-updates.js");

const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname, "..", "common", "downloaded_versions.json"
);

// ---- Helpers ----

function loadVariables() {
  const content = fs.readFileSync(variablesPath, "utf8");
  const lines = content.split(/\r?\n/);
  const vars = {};
  for (const line of lines) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (match) {
      let value = match[2].trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      vars[match[1]] = value;
    }
  }
  return vars;
}

function runCheckUpdatesJSON(version) {
  return new Promise((resolve, reject) => {
    execFile("node", [checkUpdatesScript, version, "--json"], (err, stdout) => {
      if (err) return reject(err);
      try {
        resolve(JSON.parse(stdout));
      } catch {
        reject(new Error("Failed to parse JSON from check-updates.js"));
      }
    });
  });
}

function askYesNo(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    rl.question(question + " (y/n): ", (answer) => {
      rl.close();
      resolve(answer.toLowerCase().startsWith("y"));
    });
  });
}

async function backupServer() {
  return new Promise((resolve, reject) => {
    const backupScript = path.resolve(__dirname, "../backup/backup.sh");

    console.log("Starting archive backup before update...\n");

    const child = spawn("bash", [backupScript, "--archive", "update"], {
      stdio: "inherit",
    });

    child.on("exit", (code) => {
      if (code === 0) {
        console.log("\nArchive backup completed successfully.\n");
        resolve();
      } else {
        reject(new Error(`Backup failed: backup.sh exited with code ${code}`));
      }
    });

    child.on("error", (err) => {
      reject(new Error(`Failed to start backup.sh: ${err.message}`));
    });
  });
}

// ---- Server Update (Fabric or Vanilla) ----

async function updateVanilla(versionId, metadataUrl, serverPath) {
  console.log(`Updating vanilla server to ${versionId}...`);
  const meta = await axios.get(metadataUrl);
  const serverUrl = meta.data.downloads?.server?.url;

  if (!serverUrl) throw new Error(`No vanilla server jar for ${versionId}`);

  const jarPath = path.join(serverPath, "server.jar");
  const writer = fs.createWriteStream(jarPath);
  const resp = await axios.get(serverUrl, { responseType: "stream" });

  resp.data.pipe(writer);
  await new Promise((res, rej) => {
    writer.on("finish", res);
    writer.on("error", rej);
  });

  console.log("Vanilla server updated.");
}

async function updateFabric(versionId, serverPath) {
  console.log(`Updating Fabric server for ${versionId}...`);

  const installerInfo = await axios.get(
    "https://meta.fabricmc.net/v2/versions/installer"
  );
  const stableInstaller = installerInfo.data.find((i) => i.stable);
  if (!stableInstaller) throw new Error("No stable Fabric installer found");

  const installerVer = stableInstaller.version;
  const installerJar = `fabric-installer-${installerVer}.jar`;
  const installerPath = path.join(serverPath, installerJar);

  const url = `https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installerVer}/${installerJar}`;

  const writer = fs.createWriteStream(installerPath);
  const resp = await axios.get(url, { responseType: "stream" });
  resp.data.pipe(writer);

  await new Promise((res, rej) => {
    writer.on("finish", res);
    writer.on("error", rej);
  });

  // Dynamically determine required Java version from Mojang's API
  const javaVersion = await getJavaVersionFor(versionId);
  const jabbaDir = path.join(process.env.HOME, ".jabba", "jdk");

  if (!fs.existsSync(jabbaDir)) {
    throw new Error(`Jabba JDK directory not found: ${jabbaDir}`);
  }

  const installed = fs
    .readdirSync(jabbaDir)
    .find((name) => name.includes(`@${javaVersion}.`));

  if (!installed) {
    throw new Error(
      `No Jabba Java ${javaVersion} installed. ` +
      `Install it with: jabba install adopt@${javaVersion}.0-0`
    );
  }

  const javaBin = path.join(jabbaDir, installed, "bin", "java");

  await new Promise((resolve, reject) => {
    const proc = spawn(
      javaBin,
      [
        "-jar", installerPath,
        "server",
        "-mcversion", versionId,
        "-downloadMinecraft",
      ],
      { cwd: serverPath, stdio: "inherit" }
    );

    proc.on("exit", (code) => {
      // Clean up installer jar regardless of outcome
      try { fs.unlinkSync(installerPath); } catch { /* ignore */ }
      if (code === 0) resolve();
      else reject(new Error(`Fabric installer exit code ${code}`));
    });
  });

  console.log("Fabric updated.");
}

async function applyGameUpdate(modLoader, versionId, metadataUrl, serverPath) {
  if (modLoader === "fabric") {
    return updateFabric(versionId, serverPath);
  } else {
    return updateVanilla(versionId, metadataUrl, serverPath);
  }
}

function runModUpdate(version) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [updateModsScript, version], { stdio: "inherit" });
    child.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error("update-mods.js failed"));
    });
  });
}

async function performUpdateFlow({ targetVersion, modLoader, serverPath }) {
  try {
    await backupServer();
  } catch {
    console.error("Backup failed. Aborting update.");
    process.exit(1);
  }

  const { versionId, metadataUrl } = await getVersionInfo(targetVersion, false);

  saveGameVersion(versionId);
  saveModLoader(modLoader);

  await applyGameUpdate(modLoader, versionId, metadataUrl, serverPath);
  await runModUpdate(versionId);
}

async function removeIncompatibleMods(serverPath, incompatible) {
  const modsDir = path.join(serverPath, "mods");
  if (!fs.existsSync(modsDir)) return;
  const files = fs.readdirSync(modsDir);

  for (const m of incompatible) {
    const slug = m.slug.toLowerCase();
    for (const file of files) {
      if (file.toLowerCase().includes(slug)) {
        console.log(`Removing incompatible mod: ${file}`);
        fs.unlinkSync(path.join(modsDir, file));
      }
    }
  }
}

// ---- Main ----

let removeIncompatibleModsFlag = false;

(async () => {
  try {
    const vars = loadVariables();
    const serverPath = vars.SERVER_PATH;

    const targetVersionArg = process.argv[2] || null;

    if (!fs.existsSync(serverPath)) {
      console.error("SERVER_PATH does not exist:", serverPath);
      process.exit(1);
    }

    if (!fs.existsSync(downloadedVersionsPath)) {
      throw new Error("downloaded_versions.json missing!");
    }

    const installed = JSON.parse(fs.readFileSync(downloadedVersionsPath, "utf8"));
    const targetVersion = targetVersionArg || "latest";
    const modLoader = installed.modLoader;

    console.log(`Updating to version: ${targetVersion}`);
    console.log(`Mod loader: ${modLoader}`);

    console.log("\nChecking mod compatibility...");
    const updateInfo = await runCheckUpdatesJSON(targetVersion);

    const incompatible = updateInfo.results.filter((m) =>
      ["no_versions", "no_matching_version", "error"].includes(m.status)
    );

    const allCompatible = incompatible.length === 0;

    if (!allCompatible) {
      console.log("\nSome mods are not available:");
      incompatible.forEach((m) =>
        console.log(` - ${m.slug}: ${m.message || m.status}`)
      );

      const proceed = await askYesNo("\nDo you want to update anyway?");
      if (!proceed) {
        console.log("Aborted by user.");
        process.exit(0);
      }

      removeIncompatibleModsFlag = await askYesNo(
        "Do you want to remove incompatible mods from the server?"
      );
    }

    await performUpdateFlow({ targetVersion, modLoader, serverPath });

    if (!allCompatible) {
      if (removeIncompatibleModsFlag) {
        await removeIncompatibleMods(serverPath, incompatible);
        console.log("\nUpdate completed with incompatible mods removed.");
      } else {
        console.log("\nUpdate completed with incompatible mods retained.");
      }
    } else {
      console.log("\nServer fully updated.");
    }

    process.exit(0);
  } catch (err) {
    console.error("\nUpdate failed:", err.message);
    process.exit(1);
  }
})();
