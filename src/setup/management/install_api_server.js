"use strict";

/**
 * Installs the API wrapper (mc-api-server) from the release this suite pins in
 * api-server-release.json, into <target>/services/api-server/.
 *
 * The wrapper is not part of this checkout: a host that never enables it never
 * downloads it. The release tarball is already built (dist/ included), so the
 * host only installs production dependencies.
 *
 *   node install_api_server.js --dir <path> [--check] [--force] [--dry-run]
 *                              [--tarball <file>] [--no-verify]
 *
 *   --check      print the state of <dir> as one line and change nothing:
 *                  state=<missing|unmanaged|outdated|current> installed=<v> pinned=<v>
 *                unmanaged = a copy from before releases (no .release.json).
 *   --force      reinstall even when <dir> is current
 *   --tarball    install this file instead of downloading (offline hosts)
 *   --no-verify  skip the sha256 check (a tarball you built yourself)
 *
 * MC_API_SERVER_RELEASE_BASE replaces https://github.com/<repository>/releases/download
 * (a mirror). The download is checked against the pinned sha256 either way.
 *
 * A failed download, check, unpack or `npm ci` leaves the existing install
 * untouched: everything happens in a staging folder next to <dir> first. Only
 * then are <dir>'s files replaced in place, keeping the folder itself (and so
 * any default ACL service_user.sh put on it) and the files listed in PRESERVE.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const PIN_FILE = path.resolve(__dirname, "..", "..", "..", "api-server-release.json");
const MARKER = ".release.json";
/** Written by the operator or the wrapper at runtime; survive a reinstall. */
const PRESERVE = new Set(["api-server-config.json", ".env", "variables.txt", "logs"]);
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
const REPO_RE = /^[\w.-]+\/[\w.-]+$/;
const SHA_RE = /^[0-9a-f]{64}$/;

function readPin(file = PIN_FILE) {
  const pin = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!REPO_RE.test(pin.repository || "")) throw new Error(`${file}: "repository" must be owner/name`);
  if (!VERSION_RE.test(pin.version || "")) throw new Error(`${file}: "version" must be a semver version`);
  // GitHub's release page shows asset digests as "sha256:<hex>"; accept them pasted as is.
  const sha = String(pin.sha256 || "").replace(/^sha256:/i, "").toLowerCase();
  if (sha && !SHA_RE.test(sha)) throw new Error(`${file}: "sha256" must be 64 hex characters`);
  return { repository: pin.repository, version: pin.version, sha256: sha };
}

function assetName(version) {
  return `mc-api-server-${version}.tar.gz`;
}

function releaseUrl(pin, base = process.env.MC_API_SERVER_RELEASE_BASE) {
  const root = (base || `https://github.com/${pin.repository}/releases/download`).replace(/\/+$/, "");
  return `${root}/v${pin.version}/${assetName(pin.version)}`;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/** What is in <dir> compared with the pin. */
function inspect(dir, pin) {
  const pkg = readJson(path.join(dir, "package.json"));
  const marker = readJson(path.join(dir, MARKER));
  const installed = marker?.version || pkg?.version || "";
  let state;
  if (!fs.existsSync(path.join(dir, "index.js"))) state = "missing";
  else if (!marker) state = "unmanaged";
  else if (marker.version !== pin.version || (pin.sha256 && marker.sha256 !== pin.sha256)) state = "outdated";
  else state = "current";
  return { state, installed, pinned: pin.version };
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

async function download(url, dest) {
  if (typeof fetch !== "function") throw new Error("This Node.js has no fetch(); use Node 18 or newer, or pass --tarball.");
  const res = await fetch(url, { redirect: "follow" });
  if (!res.ok) throw new Error(`Download failed: ${url} answered ${res.status}`);
  fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
}

function npmInstall(dir, log) {
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  const lock = fs.existsSync(path.join(dir, "package-lock.json"));
  const args = lock ? ["ci", "--omit=dev"] : ["install", "--omit=dev"];
  log(`npm ${args.join(" ")}`);
  execFileSync(npm, [...args, "--no-audit", "--no-fund"], { cwd: dir, stdio: ["ignore", "inherit", "inherit"] });
}

/** Replace <dir>'s contents with <staging>'s, keeping PRESERVE and the folder itself. */
function replaceContents(dir, staging) {
  fs.mkdirSync(dir, { recursive: true });
  for (const name of fs.readdirSync(dir)) {
    if (PRESERVE.has(name)) continue;
    fs.rmSync(path.join(dir, name), { recursive: true, force: true });
  }
  for (const name of fs.readdirSync(staging)) {
    if (PRESERVE.has(name) && fs.existsSync(path.join(dir, name))) continue;
    // Copied, not renamed: new files are created inside <dir> and inherit its default ACL.
    fs.cpSync(path.join(staging, name), path.join(dir, name), { recursive: true, verbatimSymlinks: true });
  }
}

/**
 * Install the pinned release into `dir`. Resolves to { state, installed, pinned }
 * as found before installing, plus `changed`.
 */
async function install({ dir, pin = readPin(), tarball = "", verify = true, force = false, dryRun = false, log = console.log }) {
  const before = inspect(dir, pin);
  if (before.state === "current" && !force) {
    log(`[api-server] ${dir} already runs release ${pin.version}.`);
    return { ...before, changed: false };
  }
  if (verify && !pin.sha256) {
    throw new Error(`api-server-release.json pins ${pin.version} without a sha256; refusing to install an unverified download.`);
  }
  const source = tarball || releaseUrl(pin);
  const what = before.state === "missing" ? "Installing" : `Replacing ${before.installed || "an unknown version"} with`;
  log(`[api-server] ${what} release ${pin.version} from ${source}`);
  if (dryRun) return { ...before, changed: true };

  const parent = path.dirname(path.resolve(dir));
  fs.mkdirSync(parent, { recursive: true });
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "mc-api-server-"));
  const staging = fs.mkdtempSync(path.join(parent, ".api-server-staging-"));
  let installedVersion = pin.version;
  try {
    let file = tarball;
    if (!file) {
      file = path.join(work, assetName(pin.version));
      await download(source, file);
    }
    if (verify) {
      const got = sha256(file);
      if (got !== pin.sha256) {
        throw new Error(
          `sha256 mismatch for ${source}: expected ${pin.sha256}, got ${got}. ` +
            `The pin needs the checksum of ${assetName(pin.version)} itself (the content of its .sha256 file), ` +
            "not the digest of the .sha256 file.",
        );
      }
    } else {
      log("[api-server] Not checking the sha256 (--no-verify).");
    }
    execFileSync("tar", ["-xzf", file, "-C", staging, "--strip-components=1"], { stdio: ["ignore", "inherit", "inherit"] });
    const pkg = readJson(path.join(staging, "package.json"));
    if (!pkg || !fs.existsSync(path.join(staging, "index.js")) || !fs.existsSync(path.join(staging, "dist", "index.js"))) {
      throw new Error("The tarball is not a built mc-api-server release (package.json, index.js or dist/index.js missing).");
    }
    if (verify && pkg.version !== pin.version) {
      throw new Error(`The tarball holds version ${pkg.version}, not the pinned ${pin.version}.`);
    }
    installedVersion = pkg.version;
    npmInstall(staging, (m) => log(`[api-server] ${m}`));
    fs.writeFileSync(
      path.join(staging, MARKER),
      JSON.stringify({ version: pkg.version, sha256: verify ? pin.sha256 : sha256(file), installedAt: new Date().toISOString() }, null, 2) + "\n",
    );
    replaceContents(dir, staging);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
    fs.rmSync(work, { recursive: true, force: true });
  }
  log(`[api-server] ${dir} now runs release ${installedVersion}.`);
  return { ...before, changed: true };
}

function parseArgs(argv) {
  const opts = { dir: "", check: false, force: false, dryRun: false, tarball: "", verify: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir") opts.dir = argv[++i] || "";
    else if (a === "--tarball") opts.tarball = argv[++i] || "";
    else if (a === "--check") opts.check = true;
    else if (a === "--force") opts.force = true;
    else if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--no-verify") opts.verify = false;
    else throw new Error(`Unknown argument: ${a}`);
  }
  if (!opts.dir) throw new Error("--dir <path> is required");
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const pin = readPin();
  if (opts.check) {
    const s = inspect(opts.dir, pin);
    console.log(`state=${s.state} installed=${s.installed || "-"} pinned=${s.pinned}`);
    return;
  }
  await install({ ...opts, tarball: opts.tarball ? path.resolve(opts.tarball) : "", pin });
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`[api-server] ${err.message}`);
    process.exit(1);
  });
}

module.exports = { readPin, releaseUrl, assetName, inspect, install, PRESERVE, MARKER };
