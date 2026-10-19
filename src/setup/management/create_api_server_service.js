"use strict";

/**
 * Deploys the mc-api-server for this MC instance.
 *
 * One api-server process handles ALL instances on this machine. On the first
 * run it installs the release pinned in api-server-release.json to
 * <target>/services/api-server/ (install_api_server.js) and creates the
 * systemd service. On subsequent runs (adding a new MC instance) it updates
 * api-server-config.json and restarts the existing service; upgrading the
 * wrapper itself is migrate.sh's job.
 *
 * Called during setup when API_SERVER.ENABLED = true in variables.json,
 * or when --api-server is passed to main.sh.
 */

const path = require("path");
const fs = require("fs");
const { execSync, execFileSync } = require("child_process");
const { writeRootFile } = require("../common/writeRootFile");
const loadVariables = require("../common/loadVariables");

// ── Paths ─────────────────────────────────────────────────────────────────

const vars = loadVariables();
const { TARGET_DIR_NAME, INSTANCE_NAME } = vars;
const apiServer = vars.API_SERVER || {};
const serverCtrl = vars.SERVER_CONTROL || {};

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, "scripts", INSTANCE_NAME);
const VARS_FILE = path.join(SCRIPTS_DIR, "common", "variables.txt");

// The api-server is shared across all instances — lives at <target>/services/api-server/
const API_SERVER_DIR = path.join(BASE_DIR, "services", "api-server");
const API_SERVER_CONFIG = path.join(API_SERVER_DIR, "api-server-config.json");
const API_SERVER_ENTRY = path.join(API_SERVER_DIR, "index.js");
const INSTALLER = path.join(__dirname, "install_api_server.js");

const currentUser = process.env.USER;
// A dedicated, unprivileged user for the wrapper (see docs/service-user.md). Without
// it the wrapper runs as the setup user, as before.
const serviceUser = apiServer.SERVICE_USER || "";
if (serviceUser && !/^[a-z_][a-z0-9_-]{0,31}$/.test(serviceUser)) {
  console.error(`[api-server] API_SERVER.SERVICE_USER "${serviceUser}" is not a valid user name.`);
  process.exit(1);
}
const runAs = serviceUser || currentUser;
// The wrapper runs scripts through sudo, and the sudoers rules name exact interpreters.
// Pin the wrapper to the same ones service_user.sh was given (setup.sh passes both).
const pinnedInterpreters = serviceUser
  ? `
Environment="MC_BASH_PATH=${execSync("command -v bash").toString().trim()}"
Environment="MC_NODE_PATH=${process.execPath}"`
  : "";
const serviceName = `${TARGET_DIR_NAME}-api-server.service`;
const serviceFile = `/etc/systemd/system/${serviceName}`;

// ── Install the pinned release (first time only) ─────────────────────────

if (!fs.existsSync(API_SERVER_ENTRY)) {
  try {
    execFileSync(process.execPath, [INSTALLER, "--dir", API_SERVER_DIR], { stdio: "inherit" });
  } catch {
    console.error("[api-server] Installing the wrapper failed (see above).");
    process.exit(1);
  }
} else {
  const { readPin, inspect } = require("./install_api_server");
  const { state, installed, pinned } = inspect(API_SERVER_DIR, readPin());
  if (state !== "current") {
    console.log(
      `[api-server] The installed wrapper (${installed || "unknown version"}) is not the pinned release ${pinned}; ` +
        "migrate.sh upgrades it.",
    );
  }
}

// ── Read instance paths from the deployed variables.txt ──────────────────

// The suite's own reader, which undoes setup's escaping (S-030): the inline
// regex here cut a value at its first escaped quote.
const { parseVariables } = require("../../scripts/update/lib/variables");
function parseVarsFile(filePath) {
  return parseVariables(fs.readFileSync(filePath, "utf-8"));
}

if (!fs.existsSync(VARS_FILE)) {
  console.error(`[api-server] variables.txt not found at ${VARS_FILE}`);
  console.error(
    "  Run the full setup first so that variables.txt is generated.",
  );
  process.exit(1);
}

const deployedVars = parseVarsFile(VARS_FILE);
const serverPath = deployedVars["SERVER_PATH"] || "";
const linuxUser = deployedVars["USER"] || "minecraft";

if (!serverPath) {
  console.error("[api-server] SERVER_PATH is not set in variables.txt");
  process.exit(1);
}

// ── Create or update api-server-config.json ───────────────────────────────

let config = {
  port: apiServer.PORT || 3000,
  apiKey: apiServer.API_KEY || "",
  instances: {},
};

if (fs.existsSync(API_SERVER_CONFIG)) {
  try {
    const existing = JSON.parse(fs.readFileSync(API_SERVER_CONFIG, "utf-8"));
    // Preserve port / apiKey from the existing config so they don't get
    // overwritten when a second instance is added.
    config = { ...existing, instances: existing.instances || {} };
  } catch (err) {
    console.warn(
      `[api-server] Could not parse existing config — overwriting: ${err.message}`,
    );
  }
}

config.instances[INSTANCE_NAME] = {
  serverPath,
  scriptsDir: SCRIPTS_DIR,
  linuxUser,
  useRcon: serverCtrl.USE_RCON === true,
  rconHost: serverCtrl.RCON_HOST || "localhost",
  rconPort: serverCtrl.RCON_PORT || 25575,
  rconPassword: serverCtrl.RCON_PASSWORD || deployedVars["RCON_PASSWORD"] || "",
  backupsPath: deployedVars["BACKUPS_PATH"] || "",
};

fs.writeFileSync(API_SERVER_CONFIG, JSON.stringify(config, null, 2), {
  mode: 0o600,
});
// Re-assert mode in case the file pre-existed with looser permissions.
fs.chmodSync(API_SERVER_CONFIG, 0o600);
if (serviceUser) {
  // chmod above resets the ACL mask, so the service user's read grant is set after it.
  try {
    execSync(`setfacl -m u:${serviceUser}:r ${JSON.stringify(API_SERVER_CONFIG)}`);
  } catch (err) {
    console.error(`[api-server] Could not let ${serviceUser} read the config (${err.message}). Run service_user.sh first.`);
    process.exit(1);
  }
}
console.log(`[api-server] Config updated: ${API_SERVER_CONFIG}`);
console.log(
  `[api-server] Instances: [${Object.keys(config.instances).join(", ")}]`,
);

// ── Create or reload the systemd service ─────────────────────────────────

const serviceExists = fs.existsSync(serviceFile);

if (!serviceExists) {
  const serviceContent = `[Unit]
Description=mc-api-server — ${TARGET_DIR_NAME}
After=network.target

[Service]
Type=simple
User=${runAs}
Group=${runAs}
WorkingDirectory=${API_SERVER_DIR}
Environment="CONFIG_FILE=${API_SERVER_CONFIG}"${pinnedInterpreters}
# Default 4 is shared by every fs.readFile/stat/readdir this process makes;
# a stats/backups/mods fan-out can starve /health's own filesystem read
# behind it. Bounded server-side concurrency (see instances/*.ts) is the
# real fix; this is cheap insurance on top of it.
Environment="UV_THREADPOOL_SIZE=8"
# Upgrade and prune jobs run in their own process group and outlive a wrapper
# restart; the next wrapper picks them up from its state folder. systemd's
# default KillMode would kill them with the wrapper.
KillMode=process
StateDirectory=${TARGET_DIR_NAME}-api-server
StateDirectoryMode=0700
Environment="MC_STATE_DIR=/var/lib/${TARGET_DIR_NAME}-api-server"
ExecStart=${process.execPath} ${API_SERVER_ENTRY}
Restart=on-failure
RestartSec=5s
# Unlike the PM2 deployment path this unit previously had no ceiling at
# all, so a leak would grow until the OS OOM-killer intervened rather than
# a clean, logged restart. 768M mirrors the PM2 ecosystem config's own
# ceiling for consistency across deployment methods.
MemoryMax=768M
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${TARGET_DIR_NAME}-api-server

[Install]
WantedBy=multi-user.target
`;

  try {
    // SEC-03: write the unit directly as root from stdin (no /tmp staging,
    // no shell). See src/setup/common/writeRootFile.js and docs/sudoers-setup.md.
    writeRootFile(serviceFile, serviceContent);
    execSync("sudo systemctl daemon-reload");
    execSync(`sudo systemctl enable ${serviceName}`);
    if (serviceUser) {
      console.log(`[api-server] Service created: ${serviceName} (started after ${serviceUser} has its grants)`);
    } else {
      execSync(`sudo systemctl start ${serviceName}`);
      console.log(`[api-server] Service created and started: ${serviceName}`);
    }
  } catch (err) {
    console.error(`[api-server] Failed to create service: ${err.message}`);
    process.exit(1);
  }
} else {
  // Service already exists — just restart it to pick up the new instance
  try {
    if (serviceUser) {
      console.log(`[api-server] Service exists: ${serviceName} (restarted after ${serviceUser} has its grants)`);
    } else {
      execSync(`sudo systemctl restart ${serviceName}`);
      console.log(`[api-server] Service restarted: ${serviceName}`);
    }
  } catch (err) {
    console.error(`[api-server] Failed to restart service: ${err.message}`);
    process.exit(1);
  }
}

console.log(`[api-server] Listening on port ${config.port}`);
