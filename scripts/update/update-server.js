"use strict";

/**
 * update-server.js
 *
 * Updates the Minecraft server (vanilla or Fabric) and all mods to the
 * specified version (or latest).
 *
 * Usage: node update-server.js [version]
 *
 * Self-contained — no dependency on the setup project directory.
 * All paths are resolved relative to this script's location.
 */

const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { spawn, execFile, execSync } = require("child_process");
const axios = require("axios");
const { parseArgs } = require("./args");

// Usage:
//   node update-server.js [version] [--version=<ver>]
//
//   version  Target MC version — positional or --version=.
//            Defaults to "latest" when omitted.

// ── Paths ─────────────────────────────────────────────────────────────────

const SCRIPT_DIR = __dirname;
const VARIABLES_PATH = path.resolve(
  SCRIPT_DIR,
  "..",
  "common",
  "variables.txt",
);
const DOWNLOADED_VERSIONS_PATH = path.resolve(
  SCRIPT_DIR,
  "..",
  "common",
  "downloaded_versions.json",
);
const UPDATE_MODS_SCRIPT = path.resolve(SCRIPT_DIR, "update-mods.js");
const CHECK_UPDATES_SCRIPT = path.resolve(SCRIPT_DIR, "check-updates.js");
const BACKUP_SCRIPT = path.resolve(SCRIPT_DIR, "..", "backup", "backup.sh");

const MOJANG_MANIFEST_URL =
  "https://launchermeta.mojang.com/mc/game/version_manifest.json";

// ── Config loading ────────────────────────────────────────────────────────

function loadVariables() {
  const content = fs.readFileSync(VARIABLES_PATH, "utf8");
  const vars = {};
  for (const line of content.split(/\r?\n/)) {
    const m = line.match(/^(\w+)=(.*)$/);
    if (!m) continue;
    let value = m[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    vars[m[1]] = value;
  }
  return vars;
}

function readDownloadedVersions() {
  try {
    return JSON.parse(fs.readFileSync(DOWNLOADED_VERSIONS_PATH, "utf8"));
  } catch {
    return {};
  }
}

function writeDownloadedVersions(data) {
  fs.writeFileSync(
    DOWNLOADED_VERSIONS_PATH,
    JSON.stringify(data, null, 2),
    "utf8",
  );
}

function saveGameVersion(versionId) {
  const data = readDownloadedVersions();
  data.gameVersion = versionId;
  writeDownloadedVersions(data);
}

function saveModLoader(modLoader) {
  const data = readDownloadedVersions();
  data.modLoader = modLoader;
  writeDownloadedVersions(data);
}

// ── Mojang version resolution ─────────────────────────────────────────────

let _manifestCache = null;

async function fetchManifest() {
  if (_manifestCache) return _manifestCache;
  const resp = await axios.get(MOJANG_MANIFEST_URL);
  _manifestCache = resp.data;
  return _manifestCache;
}

async function getVersionInfo(requestedVersion, allowSnapshot = false) {
  const manifest = await fetchManifest();
  const versionId =
    requestedVersion === "latest"
      ? allowSnapshot
        ? manifest.latest.snapshot
        : manifest.latest.release
      : requestedVersion;
  const entry = manifest.versions.find((v) => v.id === versionId);
  if (!entry)
    throw new Error(`Version '${versionId}' not found in Mojang manifest.`);
  return { versionId, metadataUrl: entry.url };
}

async function getJavaVersionFor(mcVersion) {
  const { metadataUrl } = await getVersionInfo(mcVersion);
  const resp = await axios.get(metadataUrl);
  const meta = resp.data;
  if (meta.javaVersion?.majorVersion)
    return String(meta.javaVersion.majorVersion);
  console.warn(
    `No javaVersion in Mojang metadata for ${mcVersion}. Falling back to Java 8.`,
  );
  return "8";
}

// ── Helpers ───────────────────────────────────────────────────────────────

function askYesNo(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    rl.question(`${question} (y/n): `, (answer) => {
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
  const isDiscord =
    url.includes("discord.com/api/webhooks") ||
    url.includes("discordapp.com/api/webhooks");
  const color = event.includes("failed") ? 15158332 : 3066993;
  const payload = isDiscord
    ? {
        embeds: [
          {
            title: vars.INSTANCE_NAME,
            description: message,
            color,
            timestamp: new Date().toISOString(),
            footer: { text: event },
          },
        ],
      }
    : {
        event,
        instance: vars.INSTANCE_NAME,
        message,
        timestamp: new Date().toISOString(),
      };
  axios.post(url, payload).catch(() => {});
}

function runCheckUpdatesJSON(version) {
  return new Promise((resolve, reject) => {
    execFile(
      "node",
      [CHECK_UPDATES_SCRIPT, version, "--json"],
      (err, stdout) => {
        if (err) return reject(err);
        try {
          resolve(JSON.parse(stdout));
        } catch {
          reject(new Error("Failed to parse JSON from check-updates.js"));
        }
      },
    );
  });
}

// ── Backup ────────────────────────────────────────────────────────────────

function backupServer() {
  return new Promise((resolve, reject) => {
    console.log("Starting archive backup before update...\n");
    const child = spawn("bash", [BACKUP_SCRIPT, "--archive", "update"], {
      stdio: "inherit",
    });
    child.on("exit", (code) => {
      if (code === 0) {
        console.log("\nArchive backup completed.\n");
        resolve();
      } else reject(new Error(`Backup failed (exit ${code})`));
    });
    child.on("error", (err) =>
      reject(new Error(`Failed to start backup: ${err.message}`)),
    );
  });
}

// ── Java auto-install ─────────────────────────────────────────────────────

async function ensureJavaVersion(mcVersion) {
  const requiredJava = await getJavaVersionFor(mcVersion);
  console.log(`Minecraft ${mcVersion} requires Java ${requiredJava}`);

  const jabbaDir = path.join(process.env.HOME, ".jabba", "jdk");
  if (!fs.existsSync(jabbaDir)) {
    console.log("Jabba not found. Installing via Jabba...");
    execSync(
      'bash -c "curl -sL https://github.com/shyiko/jabba/raw/master/install.sh | bash"',
      { stdio: "inherit" },
    );
  }

  const installed = fs.existsSync(jabbaDir)
    ? fs.readdirSync(jabbaDir).find((n) => n.includes(`@${requiredJava}.`))
    : null;

  if (installed) {
    console.log(`Java ${requiredJava} already installed (${installed}).`);
    return requiredJava;
  }

  console.log(`Java ${requiredJava} not found. Installing automatically...`);
  try {
    const listOutput = execSync(
      "bash -c '. ~/.jabba/jabba.sh && jabba ls-remote'",
      { encoding: "utf8" },
    );
    const candidates = listOutput
      .split("\n")
      .map((l) => l.trim())
      .filter(
        (l) =>
          l.startsWith(`adopt@${requiredJava}.`) ||
          l.startsWith(`temurin@${requiredJava}.`),
      )
      .sort()
      .reverse();
    if (!candidates.length)
      throw new Error(
        `No Jabba candidates for Java ${requiredJava}. Install manually.`,
      );
    const candidate = candidates[0];
    console.log(`Installing ${candidate}...`);
    execSync(
      `bash -c '. ~/.jabba/jabba.sh && jabba install ${candidate} && jabba use ${candidate}'`,
      { stdio: "inherit" },
    );
    console.log(`Java ${requiredJava} installed.`);
  } catch (err) {
    throw new Error(
      `Failed to auto-install Java ${requiredJava}: ${err.message}`,
    );
  }
  return requiredJava;
}

// ── Server update ─────────────────────────────────────────────────────────

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
  const info = await axios.get(
    "https://meta.fabricmc.net/v2/versions/installer",
  );
  const stableInstaller = info.data.find((i) => i.stable);
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
  const javaVersion = await getJavaVersionFor(versionId);
  const jabbaDir = path.join(process.env.HOME, ".jabba", "jdk");
  const javaInstall = fs
    .readdirSync(jabbaDir)
    .find((n) => n.includes(`@${javaVersion}.`));
  if (!javaInstall)
    throw new Error(`Java ${javaVersion} not found after install attempt.`);
  const javaBin = path.join(jabbaDir, javaInstall, "bin", "java");
  await new Promise((resolve, reject) => {
    const proc = spawn(
      javaBin,
      [
        "-jar",
        installerPath,
        "server",
        "-mcversion",
        versionId,
        "-downloadMinecraft",
      ],
      { cwd: serverPath, stdio: "inherit" },
    );
    proc.on("exit", (code) => {
      try {
        fs.unlinkSync(installerPath);
      } catch {
        /* ignore */
      }
      code === 0
        ? resolve()
        : reject(new Error(`Fabric installer exit ${code}`));
    });
  });
  console.log("Fabric updated.");
}

function runModUpdate(version) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [UPDATE_MODS_SCRIPT, version], {
      stdio: "inherit",
    });
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error("update-mods.js failed")),
    );
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

// ── Main ──────────────────────────────────────────────────────────────────

(async () => {
  const vars = loadVariables();

  try {
    const serverPath = vars.SERVER_PATH;
    const args = parseArgs({
      flags: { version: null },
      positional: ["version"],
    });

    const targetVersionArg = args.get("version");

    if (!fs.existsSync(serverPath)) {
      console.error("SERVER_PATH does not exist:", serverPath);
      process.exit(1);
    }
    if (!fs.existsSync(DOWNLOADED_VERSIONS_PATH)) {
      throw new Error("downloaded_versions.json missing!");
    }

    const installed = readDownloadedVersions();
    const modLoader = installed.modLoader;
    const { versionId, metadataUrl } = await getVersionInfo(
      targetVersionArg || "latest",
    );
    console.log(`Target version: ${versionId}`);
    console.log(`Mod loader: ${modLoader}`);

    await ensureJavaVersion(versionId);

    console.log("\nChecking mod compatibility...");
    const updateInfo = await runCheckUpdatesJSON(versionId);
    const incompatible = updateInfo.results.filter((m) =>
      ["no_versions", "no_matching_version", "error"].includes(m.status),
    );

    let removeIncompatibleModsFlag = false;

    if (incompatible.length > 0) {
      console.log("\nSome mods are not available for this version:");
      incompatible.forEach((m) =>
        console.log(` - ${m.slug}: ${m.message || m.status}`),
      );
      const proceed = await askYesNo("\nUpdate anyway?");
      if (!proceed) {
        console.log("Aborted.");
        process.exit(0);
      }
      removeIncompatibleModsFlag = await askYesNo(
        "Remove incompatible mods from the server?",
      );
    }

    try {
      await backupServer();
    } catch {
      console.error("Backup failed. Aborting update.");
      sendWebhook(
        vars,
        "update_failed",
        `Update to ${versionId} aborted: backup failed.`,
      );
      process.exit(1);
    }

    saveGameVersion(versionId);
    saveModLoader(modLoader);

    if (modLoader === "fabric") {
      await updateFabric(versionId, serverPath);
    } else {
      await updateVanilla(versionId, metadataUrl, serverPath);
    }

    await runModUpdate(versionId);

    if (incompatible.length > 0 && removeIncompatibleModsFlag) {
      await removeIncompatibleMods(serverPath, incompatible);
      console.log("\nUpdate completed with incompatible mods removed.");
    } else if (incompatible.length > 0) {
      console.log("\nUpdate completed with incompatible mods retained.");
    } else {
      console.log("\nServer fully updated.");
    }

    sendWebhook(
      vars,
      "update_complete",
      `Server updated to ${versionId} successfully.`,
    );
    process.exit(0);
  } catch (err) {
    console.error("\nUpdate failed:", err.message);
    sendWebhook(vars, "update_failed", `Update failed: ${err.message}`);
    process.exit(1);
  }
})();
