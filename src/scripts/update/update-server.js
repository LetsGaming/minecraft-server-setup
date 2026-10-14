"use strict";

/**
 * update-server.js
 *
 * Updates the Minecraft server (vanilla or Fabric) and all mods to the
 * specified version (or latest).
 *
 * Usage: node update-server.js [version] [--plan | --apply] [--json] [--yes]
 *                              [--keep-incompatible]
 *
 *   (no mode)  Interactive update for a person at a terminal: checks mods,
 *              asks, takes the backup, swaps the jar, updates the mods.
 *              Does NOT stop or start the server; stop it first.
 *   --plan     Changes nothing. Reports target version, the Java it needs and
 *              each installed mod's verdict. With --json, one JSON object.
 *   --apply    The jar swap and the mod update only, no prompts and no
 *              backup. For upgrade-server.js, which stops the server and
 *              takes the backup itself. With --json, NDJSON progress lines
 *              and a final {"ok":...} line on stdout.
 *   --yes      Interactive mode: answer "update anyway" yes, never remove mods.
 *   --keep-incompatible  Do not disable mods that have no build for the
 *              target. (--apply never disables them; the caller decides.)
 *
 * Self-contained: no dependency on the setup project directory.
 * All paths are resolved relative to this script's location.
 */

const fs = require("fs");
const path = require("path");
const { readManifest, writeManifest } = require("./lib/manifest");
const readline = require("readline");
const { spawn, execFile, execSync, execFileSync } = require("child_process");
const axios = require("axios");
// S-015: a half-open connection must not hang this script forever, least of
// all during an upgrade, with the server stopped and the lock held. File
// downloads set their own deadlines (lib/download.js).
axios.defaults.timeout = axios.defaults.timeout || 30_000;
const { parseArgs } = require("./lib/args");
const { loadVariables: readVariables } = require("./lib/variables");
const { downloadVerified } = require("./lib/download");
const { createJsonMode } = require("./lib/json-mode");

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
const TOGGLE_MOD_SCRIPT = path.resolve(SCRIPT_DIR, "toggle-mod.js");
const BACKUP_SCRIPT = path.resolve(SCRIPT_DIR, "..", "backup", "backup.sh");

const MOJANG_MANIFEST_URL =
  "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

/** Statuses from check-updates.js that mean "no build for the target". */
const UNAVAILABLE_STATUSES = ["no_versions", "no_matching_version", "error"];

// In --json mode stdout carries only our own JSON lines, so child processes
// write to stderr instead of inheriting stdout.
let JSON_MODE = false;
function childStdio() {
  return JSON_MODE ? ["ignore", 2, 2] : "inherit";
}

// ── Config loading ────────────────────────────────────────────────────────

function loadVariables() {
  return readVariables(VARIABLES_PATH);
}

// A corrupt manifest is an error (S-024): read as {}, the next save kept only
// gameVersion and dropped every mod entry.
function readDownloadedVersions() {
  return readManifest(DOWNLOADED_VERSIONS_PATH, { missingOk: true });
}

function writeDownloadedVersions(data) {
  writeManifest(DOWNLOADED_VERSIONS_PATH, data);
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

function unavailableMods(updateInfo) {
  return updateInfo.results.filter((m) =>
    UNAVAILABLE_STATUSES.includes(m.status),
  );
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

// SEC-02: install Jabba without `curl | bash`. Download the installer, verify
// its SHA-256 against a pinned value (overridable via JABBA_INSTALL_SHA256),
// then run it. Uses the maintained Jabba-Team fork, not the abandoned shyiko
// repo. Keep the pinned hash in sync with src/vanilla/download/install_jabba.sh.
function installJabbaVerified() {
  const os = require("os");
  const crypto = require("crypto");
  const installUrl =
    process.env.JABBA_INSTALL_URL ||
    // Jabba 0.15.0, by commit (S-027): the pinned hash below is of this exact
    // file, and a branch URL broke every install the day upstream changed it.
    "https://raw.githubusercontent.com/Jabba-Team/jabba/b045bf217b9e2890c37a767097d7d2e8f147ad97/install.sh";
  const expectedSha =
    process.env.JABBA_INSTALL_SHA256 ||
    "7298872bae6a19bf22b36c302cb260e6fa88cc09ee21d50cdd0755b4270a9e5e";

  const tmp = path.join(
    os.tmpdir(),
    `jabba-install-${process.pid}-${Date.now()}.sh`,
  );
  try {
    // -f: fail on HTTP error, --proto =https / --tlsv1.2: refuse downgrades.
    execSync(
      `curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 ${JSON.stringify(installUrl)} -o ${JSON.stringify(tmp)}`,
      { stdio: childStdio(), timeout: 150_000 },
    );
    const actualSha = crypto
      .createHash("sha256")
      .update(fs.readFileSync(tmp))
      .digest("hex");
    if (actualSha !== expectedSha) {
      throw new Error(
        `Jabba installer checksum mismatch, refusing to run.\n` +
          `  expected: ${expectedSha}\n  actual:   ${actualSha}\n` +
          `  If you bumped the installer, update the pinned hash ` +
          `(or set JABBA_INSTALL_SHA256).`,
      );
    }
    console.log("[update-server] Jabba installer checksum OK, running.");
    execSync(`bash ${JSON.stringify(tmp)}`, { stdio: childStdio(), timeout: 10 * 60_000 });
  } finally {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      /* best-effort cleanup */
    }
  }
}

function jabbaJdkDir() {
  return path.join(process.env.HOME, ".jabba", "jdk");
}

/**
 * Order Jabba JDK names ("temurin@21.0.10") by their version numbers, newest
 * first. A plain string sort put 21.0.9 after 21.0.10 (S-030).
 */
function compareJdkNames(a, b) {
  const nums = (n) => (n.split("@")[1] ?? "").split(/[.+_-]/).map((x) => Number.parseInt(x, 10) || 0);
  const x = nums(a);
  const y = nums(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (y[i] ?? 0) - (x[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

/** The newest installed Jabba JDK directory name for a Java major version, or null. */
function findInstalledJava(requiredJava) {
  const jabbaDir = jabbaJdkDir();
  if (!fs.existsSync(jabbaDir)) return null;
  const matches = fs.readdirSync(jabbaDir).filter((n) => n.includes(`@${requiredJava}.`));
  return matches.sort(compareJdkNames)[0] ?? null;
}

/**
 * Point the server's JAVA= at `javaBin` (S-007). Vanilla installs launch
 * ${JAVA} from <server>/variables.txt, which setup wrote once; an upgrade to
 * a version that needs a newer Java installed that JDK and then started the
 * old one, so it always failed and rolled back. The line lives in the server
 * folder, so the job's restore puts the old one back if the upgrade fails.
 * Installs whose start does not read JAVA= are left alone.
 */
function setServerJava(serverPath, javaBin) {
  const file = path.join(serverPath, "variables.txt");
  let content;
  try {
    content = fs.readFileSync(file, "utf8");
  } catch {
    return false;
  }
  if (!/^JAVA=.*$/m.test(content)) return false;
  if (!/^[A-Za-z0-9._/+@-]+$/.test(javaBin)) {
    throw new Error(`Refusing to write an unusual Java path into variables.txt: ${javaBin}`);
  }
  const next = content.replace(/^JAVA=.*$/m, `JAVA="${javaBin}"`);
  if (next === content) return true;
  const tmp = `${file}.${process.pid}.tmp`;
  const mode = fs.statSync(file).mode & 0o7777;
  fs.writeFileSync(tmp, next, { mode });
  fs.renameSync(tmp, file);
  return true;
}

async function ensureJavaVersion(mcVersion) {
  const requiredJava = await getJavaVersionFor(mcVersion);
  console.log(`Minecraft ${mcVersion} requires Java ${requiredJava}`);

  if (!fs.existsSync(jabbaJdkDir())) {
    console.log("Jabba not found. Installing via Jabba...");
    installJabbaVerified();
  }

  const installed = findInstalledJava(requiredJava);

  if (installed) {
    console.log(`Java ${requiredJava} already installed (${installed}).`);
    return { requiredJava, javaBin: path.join(jabbaJdkDir(), installed, "bin", "java") };
  }

  console.log(`Java ${requiredJava} not found. Installing automatically...`);
  try {
    const listOutput = execSync(
      "bash -c '. ~/.jabba/jabba.sh && jabba ls-remote'",
      { encoding: "utf8", timeout: 120_000 },
    );
    const candidates = listOutput
      .split("\n")
      .map((l) => l.trim())
      .filter(
        (l) =>
          l.startsWith(`adopt@${requiredJava}.`) ||
          l.startsWith(`temurin@${requiredJava}.`),
      )
      .sort(compareJdkNames);
    if (!candidates.length)
      throw new Error(
        `No Jabba candidates for Java ${requiredJava}. Install manually.`,
      );
    const candidate = candidates[0];
    console.log(`Installing ${candidate}...`);
    execSync(
      `bash -c '. ~/.jabba/jabba.sh && jabba install ${candidate} && jabba use ${candidate}'`,
      // S-015: a JDK install that stalls must not hold the upgrade forever.
      { stdio: childStdio(), timeout: 20 * 60_000 },
    );
    console.log(`Java ${requiredJava} installed.`);
    return { requiredJava, javaBin: path.join(jabbaJdkDir(), candidate, "bin", "java") };
  } catch (err) {
    throw new Error(
      `Failed to auto-install Java ${requiredJava}: ${err.message}`,
    );
  }
}

// ── Server update ─────────────────────────────────────────────────────────

async function updateVanilla(versionId, metadataUrl, serverPath) {
  console.log(`Updating vanilla server to ${versionId}...`);
  const meta = await axios.get(metadataUrl);
  const serverUrl = meta.data.downloads?.server?.url;
  if (!serverUrl) throw new Error(`No vanilla server jar for ${versionId}`);
  const serverSha1 = meta.data.downloads.server.sha1;
  if (!serverSha1) {
    throw new Error(`Mojang published no sha1 for the ${versionId} server jar`);
  }
  await downloadVerified(serverUrl, path.join(serverPath, "server.jar"), {
    sha1: serverSha1,
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
  const javaInstall = findInstalledJava(javaVersion);
  if (!javaInstall)
    throw new Error(`Java ${javaVersion} not found after install attempt.`);
  const javaBin = path.join(jabbaJdkDir(), javaInstall, "bin", "java");
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
      { cwd: serverPath, stdio: childStdio() },
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
    proc.on("error", reject);
  });
  console.log("Fabric updated.");
}

/**
 * Update every mod for `version`. Resolves with the mods that could not be
 * updated (S-014): update-mods carries on past a failed download or a hash
 * mismatch and exits 0, so its summary is the only place that says a mod is
 * still on its old build.
 */
function runModUpdate(version) {
  return new Promise((resolve, reject) => {
    const stdio = childStdio();
    const child = spawn("node", [UPDATE_MODS_SCRIPT, version, "--json"], {
      stdio: ["ignore", "pipe", Array.isArray(stdio) ? stdio[2] : "inherit"],
    });
    let out = "";
    child.stdout.on("data", (d) => {
      out += d.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error("update-mods.js failed"));
      const last = out.trim().split("\n").reverse().find((l) => l.startsWith("{"));
      let summary;
      try {
        summary = JSON.parse(last ?? "");
      } catch {
        return reject(new Error("update-mods.js gave no summary"));
      }
      if (!summary.ok) return reject(new Error(summary.error || "update-mods.js failed"));
      resolve((summary.failed ?? []).map((f) => ({ slug: String(f.slug), error: String(f.error ?? "") })));
    });
  });
}

/**
 * Disable (not delete) mods with no build for the target. toggle-mod.js moves
 * the jar to mods/disabled/ by the manifest's recorded filename, so the move is
 * exact and reversible. Returns the slugs that could not be disabled.
 */
function disableMods(incompatible) {
  const failed = [];
  for (const m of incompatible) {
    try {
      execFileSync("node", [TOGGLE_MOD_SCRIPT, m.slug, "--disable", "--json"], {
        stdio: ["ignore", "pipe", "pipe"],
      });
      console.log(`Disabled incompatible mod: ${m.slug}`);
    } catch {
      console.warn(`Could not disable ${m.slug}.`);
      failed.push(m.slug);
    }
  }
  return failed;
}

/** Swap the server jar for the target, THEN record the new version. */
async function swapServer({ modLoader, versionId, metadataUrl, serverPath }) {
  if (modLoader === "fabric") {
    await updateFabric(versionId, serverPath);
  } else {
    await updateVanilla(versionId, metadataUrl, serverPath);
  }
  saveGameVersion(versionId);
  saveModLoader(modLoader);
}

// ── Modes ─────────────────────────────────────────────────────────────────

function requireServerSetup(serverPath) {
  if (!fs.existsSync(serverPath)) {
    throw new Error(`SERVER_PATH does not exist: ${serverPath}`);
  }
  if (!fs.existsSync(DOWNLOADED_VERSIONS_PATH)) {
    throw new Error("downloaded_versions.json missing!");
  }
}

/** --plan: look, never touch. */
async function planMode({ serverPath, targetVersionArg, emit }) {
  requireServerSetup(serverPath);
  const installed = readDownloadedVersions();
  const { versionId } = await getVersionInfo(targetVersionArg || "latest");
  const requiredJava = await getJavaVersionFor(versionId);
  const updateInfo = await runCheckUpdatesJSON(versionId);
  emit({
    ok: true,
    current: installed.gameVersion ?? null,
    target: versionId,
    modLoader: installed.modLoader ?? null,
    java: {
      required: requiredJava,
      installed: findInstalledJava(requiredJava) !== null,
    },
    mods: updateInfo.results.map((m) => ({
      slug: m.slug,
      status: m.status,
      message: m.message ?? null,
    })),
    unavailable: unavailableMods(updateInfo).map((m) => m.slug),
  });
}

/** --apply: jar swap and mod update for a caller that already stopped and backed up. */
async function applyMode({ serverPath, targetVersionArg, emit }) {
  requireServerSetup(serverPath);
  const installed = readDownloadedVersions();
  const { versionId, metadataUrl } = await getVersionInfo(
    targetVersionArg || "latest",
  );
  emit({ phase: "java", msg: `Ensuring Java for ${versionId}` });
  const { javaBin } = await ensureJavaVersion(versionId);
  if (setServerJava(serverPath, javaBin)) {
    emit({ phase: "java", msg: `The server now starts with ${javaBin}` });
  }
  emit({ phase: "jar", msg: `Installing the ${versionId} server` });
  await swapServer({
    modLoader: installed.modLoader,
    versionId,
    metadataUrl,
    serverPath,
  });
  emit({ phase: "mods", msg: "Updating mods" });
  const modUpdateFailed = await runModUpdate(versionId);
  if (modUpdateFailed.length > 0) {
    emit({
      phase: "mods",
      msg: `Could not update: ${modUpdateFailed.map((f) => `${f.slug} (${f.error})`).join(", ")}`,
    });
  }
  emit({ ok: true, version: versionId, modUpdateFailed: modUpdateFailed.map((f) => f.slug) });
}

/** The interactive flow for a person at a terminal. */
async function interactiveMode({ vars, serverPath, args }) {
  requireServerSetup(serverPath);
  const installed = readDownloadedVersions();
  const modLoader = installed.modLoader;
  const { versionId, metadataUrl } = await getVersionInfo(
    args.get("version") || "latest",
  );
  console.log(`Target version: ${versionId}`);
  console.log(`Mod loader: ${modLoader}`);

  const { javaBin } = await ensureJavaVersion(versionId);
  if (setServerJava(serverPath, javaBin)) console.log(`The server now starts with ${javaBin}`);

  console.log("\nChecking mod compatibility...");
  const updateInfo = await runCheckUpdatesJSON(versionId);
  const incompatible = unavailableMods(updateInfo);

  let disableIncompatible = false;

  if (incompatible.length > 0) {
    console.log("\nSome mods are not available for this version:");
    incompatible.forEach((m) =>
      console.log(` - ${m.slug}: ${m.message || m.status}`),
    );
    const proceed = args.bool("yes") || (await askYesNo("\nUpdate anyway?"));
    if (!proceed) {
      console.log("Aborted.");
      process.exit(0);
    }
    disableIncompatible =
      !args.bool("yes") &&
      !args.bool("keep-incompatible") &&
      (await askYesNo(
        "Disable incompatible mods (moved to mods/disabled, reversible)?",
      ));
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

  await swapServer({ modLoader, versionId, metadataUrl, serverPath });
  const modUpdateFailed = await runModUpdate(versionId);
  for (const f of modUpdateFailed) console.warn(`[WARN] ${f.slug} was not updated: ${f.error}`);

  if (incompatible.length > 0 && disableIncompatible) {
    disableMods(incompatible);
    console.log("\nUpdate completed with incompatible mods disabled.");
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
}

// ── Main ──────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs({
    flags: { version: null },
    boolFlags: ["plan", "apply", "json", "yes", "keep-incompatible"],
    positional: ["version"],
  });
  JSON_MODE = args.bool("json");
  const jsonMode = createJsonMode(JSON_MODE, {
    captureErrors: true,
    silenceWarn: true,
    silenceStdoutWrite: true,
  });
  const emit = (obj) => {
    if (JSON_MODE) jsonMode.emit(obj);
  };

  if (args.bool("plan") && args.bool("apply")) {
    emit({ ok: false, error: "Use either --plan or --apply, not both." });
    console.error("Use either --plan or --apply, not both.");
    process.exit(2);
  }

  const requested = args.get("version");
  // S-022: the version must look like one, and --apply must be told which:
  // defaulting to "latest" there turned a mangled argument into an upgrade to
  // a version nobody chose.
  if (requested !== null && requested !== "latest" && !/^[0-9A-Za-z][0-9A-Za-z._+-]{0,39}$/.test(requested)) {
    emit({ ok: false, error: `Not a Minecraft version: ${JSON.stringify(requested)}` });
    console.error(`Not a Minecraft version: ${JSON.stringify(requested)}`);
    process.exit(2);
  }
  if (args.bool("apply") && (requested === null || requested === "latest")) {
    emit({ ok: false, error: "--apply needs the exact version to install." });
    console.error("--apply needs the exact version to install.");
    process.exit(2);
  }

  const vars = loadVariables();
  const serverPath = vars.SERVER_PATH;
  const ctx = {
    vars,
    serverPath,
    args,
    targetVersionArg: args.get("version"),
    emit,
  };

  try {
    if (args.bool("plan")) {
      await planMode(ctx);
    } else if (args.bool("apply")) {
      await applyMode(ctx);
    } else {
      await interactiveMode(ctx);
    }
    process.exit(0);
  } catch (err) {
    emit({ ok: false, error: err.message });
    console.error("\nUpdate failed:", err.message);
    if (!args.bool("plan") && !args.bool("apply")) {
      sendWebhook(vars, "update_failed", `Update failed: ${err.message}`);
    }
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = { unavailableMods, UNAVAILABLE_STATUSES, setServerJava, compareJdkNames };
