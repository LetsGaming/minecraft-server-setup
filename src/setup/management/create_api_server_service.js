"use strict";

/**
 * Deploys the mc-api-server for this MC instance.
 *
 * One api-server process handles ALL instances on this machine. On the first
 * run it copies the api-server to <target>/api-server/ and creates the
 * systemd service. On subsequent runs (adding a new MC instance) it updates
 * api-server-config.json and restarts the existing service.
 *
 * Called during setup when API_SERVER.ENABLED = true in variables.json,
 * or when --api-server is passed to main.sh.
 *
 * Prerequisites:
 *   git submodule update --init   (populates scripts/api-server/)
 */

const path = require("path");
const fs = require("fs");
const { execSync } = require("child_process");
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

// Source: the submodule in this setup repo (scripts/api-server/)
const SETUP_REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const API_SERVER_SRC = path.join(
  SETUP_REPO_ROOT,
  "src",
  "scripts",
  "api-server",
);

const currentUser = process.env.USER;
const serviceName = `${TARGET_DIR_NAME}-api-server.service`;
const serviceFile = `/etc/systemd/system/${serviceName}`;

// ── Guard: submodule must be populated ───────────────────────────────────

if (!fs.existsSync(path.join(API_SERVER_SRC, "index.js"))) {
  console.error(
    "[api-server] scripts/api-server/ is missing or empty.\n" +
      "  Initialise the submodule first:\n" +
      "    git submodule update --init",
  );
  process.exit(1);
}

// ── Deploy api-server (first time only) ──────────────────────────────────

if (!fs.existsSync(API_SERVER_ENTRY)) {
  console.log("[api-server] Deploying api-server to", API_SERVER_DIR);
  fs.mkdirSync(path.dirname(API_SERVER_DIR), { recursive: true });
  fs.cpSync(API_SERVER_SRC, API_SERVER_DIR, { recursive: true });
}

if (!fs.existsSync(path.join(API_SERVER_DIR, "node_modules", "express"))) {
  console.log("[api-server] Installing dependencies...");
  try {
    execSync("npm install --omit=dev", {
      cwd: API_SERVER_DIR,
      stdio: "inherit",
    });
  } catch (err) {
    console.error(`[api-server] npm install failed: ${err.message}`);
    process.exit(1);
  }
}

// ── Read instance paths from the deployed variables.txt ──────────────────

// Inline parser — avoids a dependency on the api-server submodule's parseVars.js
function parseVarsFile(filePath) {
  const vars = {};
  for (const line of fs.readFileSync(filePath, "utf-8").split(/\r?\n/)) {
    const m = line.match(/^(\w+)="?([^"]*)"?$/);
    if (m) vars[m[1]] = m[2];
  }
  return vars;
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
User=${currentUser}
Group=${currentUser}
WorkingDirectory=${API_SERVER_DIR}
Environment="CONFIG_FILE=${API_SERVER_CONFIG}"
ExecStart=/usr/bin/node ${API_SERVER_ENTRY}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${TARGET_DIR_NAME}-api-server

[Install]
WantedBy=multi-user.target
`;

  try {
    const tmpFile = path.join("/tmp", `mc-api-service-${Date.now()}.tmp`);
    fs.writeFileSync(tmpFile, serviceContent, "utf-8");
    execSync(`sudo mv "${tmpFile}" "${serviceFile}"`);
    execSync(`sudo chmod 644 "${serviceFile}"`);
    execSync("sudo systemctl daemon-reload");
    execSync(`sudo systemctl enable ${serviceName}`);
    execSync(`sudo systemctl start ${serviceName}`);
    console.log(`[api-server] Service created and started: ${serviceName}`);
  } catch (err) {
    console.error(`[api-server] Failed to create service: ${err.message}`);
    process.exit(1);
  }
} else {
  // Service already exists — just restart it to pick up the new instance
  try {
    execSync(`sudo systemctl restart ${serviceName}`);
    console.log(`[api-server] Service restarted: ${serviceName}`);
  } catch (err) {
    console.error(`[api-server] Failed to restart service: ${err.message}`);
    process.exit(1);
  }
}

console.log(`[api-server] Listening on port ${config.port}`);
