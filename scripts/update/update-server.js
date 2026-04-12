const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { spawn, execFile, execSync } = require("child_process");

// Import shared utilities
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
  const vars = {};
  for (const line of content.split(/\r?\n/)) {
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
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question + " (y/n): ", (answer) => {
      rl.close();
      resolve(answer.toLowerCase().startsWith("y"));
    });
  });
}

function sendWebhook(vars, event, message) {
  const url = vars.WEBHOOK_URL;
  if (!url || url === "none") return;
  const events = (vars.WEBHOOK_EVENTS || "").split(" ");
  if (events.length > 0 && !events.includes(event)) return;

  const isDiscord = url.includes("discord.com/api/webhooks") || url.includes("discordapp.com/api/webhooks");
  const color = event.includes("failed") ? 15158332 : 3066993;

  const payload = isDiscord
    ? { embeds: [{ title: vars.INSTANCE_NAME, description: message, color, timestamp: new Date().toISOString(), footer: { text: event } }] }
    : { event, instance: vars.INSTANCE_NAME, message, timestamp: new Date().toISOString() };

  axios.post(url, payload).catch(() => {});
}

// ---- Backup ----

async function backupServer() {
  return new Promise((resolve, reject) => {
    const backupScript = path.resolve(__dirname, "../backup/backup.sh");
    console.log("Starting archive backup before update...\n");
    const child = spawn("bash", [backupScript, "--archive", "update"], { stdio: "inherit" });
    child.on("exit", (code) => {
      if (code === 0) { console.log("\nArchive backup completed.\n"); resolve(); }
      else reject(new Error(`Backup failed (exit code ${code})`));
    });
    child.on("error", (err) => reject(new Error(`Failed to start backup: ${err.message}`)));
  });
}

// ---- Java auto-install ----

async function ensureJavaVersion(mcVersion) {
  const requiredJava = await getJavaVersionFor(mcVersion);
  console.log(`Minecraft ${mcVersion} requires Java ${requiredJava}`);

  const jabbaDir = path.join(process.env.HOME, ".jabba", "jdk");
  if (!fs.existsSync(jabbaDir)) {
    console.log("Jabba not found. Installing Java via Jabba...");
    execSync('bash -c "curl -sL https://github.com/shyiko/jabba/raw/master/install.sh | bash"', { stdio: "inherit" });
  }

  const installed = fs.existsSync(jabbaDir)
    ? fs.readdirSync(jabbaDir).find((name) => name.includes(`@${requiredJava}.`))
    : null;

  if (installed) {
    console.log(`Java ${requiredJava} already installed (${installed}).`);
    return requiredJava;
  }

  console.log(`Java ${requiredJava} not found. Installing automatically...`);

  // Find the best available candidate from Jabba
  try {
    const listOutput = execSync(
      `bash -c '. ~/.jabba/jabba.sh && jabba ls-remote'`,
      { encoding: "utf8" }
    );
    const candidates = listOutput
      .split("\n")
      .map(l => l.trim())
      .filter(l => l.startsWith(`adopt@${requiredJava}.`) || l.startsWith(`temurin@${requiredJava}.`))
      .sort()
      .reverse();

    if (candidates.length === 0) {
      throw new Error(`No Jabba candidates found for Java ${requiredJava}. Install manually.`);
    }

    const candidate = candidates[0];
    console.log(`Installing ${candidate}...`);
    execSync(
      `bash -c '. ~/.jabba/jabba.sh && jabba install ${candidate} && jabba use ${candidate}'`,
      { stdio: "inherit" }
    );
    console.log(`Java ${requiredJava} installed successfully.`);
  } catch (err) {
    throw new Error(`Failed to auto-install Java ${requiredJava}: ${err.message}`);
  }

  return requiredJava;
}

// ---- Config diff ----

async function diffServerProperties(versionId, metadataUrl, serverPath) {
  try {
    const propsPath = path.join(serverPath, "server.properties");
    if (!fs.existsSync(propsPath)) return;

    // Parse existing properties
    const existing = new Map();
    const content = fs.readFileSync(propsPath, "utf-8");
    for (const line of content.split(/\r?\n/)) {
      if (line.startsWith("#") || !line.includes("=")) continue;
      const [key, ...rest] = line.split("=");
      existing.set(key.trim(), rest.join("=").trim());
    }

    // Download default server.jar properties from metadata
    const meta = await axios.get(metadataUrl);
    const serverUrl = meta.data.downloads?.server?.url;
    if (!serverUrl) return;

    // We can't easily extract default properties without running the jar,
    // but we can check the Mojang changelog for new properties
    // For now, just note any keys in existing that have empty values
    const emptyKeys = [];
    for (const [key, value] of existing) {
      if (value === "" && key !== "level-seed" && key !== "resource-pack" && key !== "resource-pack-sha1") {
        emptyKeys.push(key);
      }
    }

    if (emptyKeys.length > 0) {
      console.log("\n[INFO] The following server.properties keys are empty (may need values):");
      for (const key of emptyKeys) {
        console.log(`  - ${key}`);
      }
    }

    console.log(`[INFO] Server properties file has ${existing.size} keys configured.`);
  } catch {
    // Non-critical, don't fail the update
  }
}

// ---- Server update (Fabric or Vanilla) ----

async function updateVanilla(versionId, metadataUrl, serverPath) {
  console.log(`Updating vanilla server to ${versionId}...`);
  const meta = await axios.get(metadataUrl);
  const serverUrl = meta.data.downloads?.server?.url;
  if (!serverUrl) throw new Error(`No vanilla server jar for ${versionId}`);

  const jarPath = path.join(serverPath, "server.jar");
  const writer = fs.createWriteStream(jarPath);
  const resp = await axios.get(serverUrl, { responseType: "stream" });
  resp.data.pipe(writer);
  await new Promise((res, rej) => { writer.on("finish", res); writer.on("error", rej); });
  console.log("Vanilla server updated.");
}

async function updateFabric(versionId, serverPath) {
  console.log(`Updating Fabric server for ${versionId}...`);

  const installerInfo = await axios.get("https://meta.fabricmc.net/v2/versions/installer");
  const stableInstaller = installerInfo.data.find((i) => i.stable);
  if (!stableInstaller) throw new Error("No stable Fabric installer found");

  const installerVer = stableInstaller.version;
  const installerJar = `fabric-installer-${installerVer}.jar`;
  const installerPath = path.join(serverPath, installerJar);
  const url = `https://maven.fabricmc.net/net/fabricmc/fabric-installer/${installerVer}/${installerJar}`;

  const writer = fs.createWriteStream(installerPath);
  const resp = await axios.get(url, { responseType: "stream" });
  resp.data.pipe(writer);
  await new Promise((res, rej) => { writer.on("finish", res); writer.on("error", rej); });

  const javaVersion = await getJavaVersionFor(versionId);
  const jabbaDir = path.join(process.env.HOME, ".jabba", "jdk");
  const installed = fs.readdirSync(jabbaDir).find((name) => name.includes(`@${javaVersion}.`));
  if (!installed) throw new Error(`No Jabba Java ${javaVersion} found after auto-install attempt.`);

  const javaBin = path.join(jabbaDir, installed, "bin", "java");

  await new Promise((resolve, reject) => {
    const proc = spawn(javaBin, ["-jar", installerPath, "server", "-mcversion", versionId, "-downloadMinecraft"],
      { cwd: serverPath, stdio: "inherit" });
    proc.on("exit", (code) => {
      try { fs.unlinkSync(installerPath); } catch { /* ignore */ }
      if (code === 0) resolve();
      else reject(new Error(`Fabric installer exit code ${code}`));
    });
  });

  console.log("Fabric updated.");
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

(async () => {
  const vars = loadVariables();

  try {
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

    // Resolve the actual version ID
    const { versionId, metadataUrl } = await getVersionInfo(targetVersion, false);
    console.log(`Target version: ${versionId}`);
    console.log(`Mod loader: ${modLoader}`);

    // Auto-install Java if needed
    await ensureJavaVersion(versionId);

    // Check mod compatibility
    console.log("\nChecking mod compatibility...");
    const updateInfo = await runCheckUpdatesJSON(versionId);

    const incompatible = updateInfo.results.filter((m) =>
      ["no_versions", "no_matching_version", "error"].includes(m.status)
    );

    let removeIncompatibleModsFlag = false;
    const allCompatible = incompatible.length === 0;

    if (!allCompatible) {
      console.log("\nSome mods are not available for this version:");
      incompatible.forEach((m) => console.log(` - ${m.slug}: ${m.message || m.status}`));

      const proceed = await askYesNo("\nDo you want to update anyway?");
      if (!proceed) {
        console.log("Aborted by user.");
        process.exit(0);
      }
      removeIncompatibleModsFlag = await askYesNo("Do you want to remove incompatible mods from the server?");
    }

    // Backup
    try {
      await backupServer();
    } catch {
      console.error("Backup failed. Aborting update.");
      sendWebhook(vars, "update_failed", `Update to ${versionId} aborted: backup failed.`);
      process.exit(1);
    }

    // Save version info
    saveGameVersion(versionId);
    saveModLoader(modLoader);

    // Apply game update
    if (modLoader === "fabric") {
      await updateFabric(versionId, serverPath);
    } else {
      await updateVanilla(versionId, metadataUrl, serverPath);
    }

    // Update mods
    await runModUpdate(versionId);

    // Config diff
    await diffServerProperties(versionId, metadataUrl, serverPath);

    // Handle incompatible mods
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

    sendWebhook(vars, "update_complete", `Server updated to ${versionId} successfully.`);
    process.exit(0);
  } catch (err) {
    console.error("\nUpdate failed:", err.message);
    sendWebhook(vars, "update_failed", `Update failed: ${err.message}`);
    process.exit(1);
  }
})();
