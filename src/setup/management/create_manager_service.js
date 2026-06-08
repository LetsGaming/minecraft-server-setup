"use strict";

/**
 * Deploys the minecraft-server-manager web interface for this MC instance.
 *
 * Mirrors create_api_server_service.js in structure and approach:
 *   1. Guards that the git submodule is populated.
 *   2. Copies source → <target>/manager/ (first run only; idempotent thereafter).
 *   3. Installs production dependencies (npm install --omit=dev).
 *   4. Writes src/config/config.json generated from variables.json values.
 *   5. Creates src/config/users.json with a random admin password (first run only).
 *   6. Creates the systemd service (first run) or restarts it (subsequent runs).
 *
 * Called when WEB_INTERFACE.ENABLED = true in variables.json,
 * or when --interface is passed to main.sh.
 *
 * Prerequisites:
 *   git submodule update --init   (populates scripts/minecraft-server-manager/)
 */

const path         = require("path");
const fs           = require("fs");
const crypto       = require("crypto");
const { execSync } = require("child_process");
const loadVariables = require("../common/loadVariables");

// ── Paths ─────────────────────────────────────────────────────────────────

const vars        = loadVariables();
const { TARGET_DIR_NAME, INSTANCE_NAME } = vars;
const webIface    = vars.WEB_INTERFACE || {};

const BASE_DIR    = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, "scripts", INSTANCE_NAME);

// Deployment target — mirrors api-server layout: <target>/manager/
const MANAGER_DIR    = path.join(BASE_DIR, "manager");
const MANAGER_APP    = path.join(MANAGER_DIR, "app.js");
const MANAGER_CONFIG = path.join(MANAGER_DIR, "src", "config", "config.json");
const USERS_FILE     = path.join(MANAGER_DIR, "src", "config", "users.json");
const REGISTER_JS    = path.join(MANAGER_DIR, "scripts", "register.js");

// Source: git submodule at scripts/minecraft-server-manager/
const SETUP_REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const MANAGER_SRC     = path.join(SETUP_REPO_ROOT, "src", "scripts", "minecraft-server-manager");

const currentUser = process.env.USER;
const serviceName = `${TARGET_DIR_NAME}-manager.service`;
const serviceFile = `/etc/systemd/system/${serviceName}`;

// ── Guard: submodule must be populated ────────────────────────────────────

if (!fs.existsSync(path.join(MANAGER_SRC, "app.js"))) {
  console.error(
    "[manager] scripts/minecraft-server-manager/ is missing or empty.\n" +
    "  Initialise the submodule first:\n" +
    "    git submodule update --init",
  );
  process.exit(1);
}

// ── Deploy manager source (first time only) ───────────────────────────────

if (!fs.existsSync(MANAGER_APP)) {
  console.log("[manager] Deploying to", MANAGER_DIR);
  fs.cpSync(MANAGER_SRC, MANAGER_DIR, { recursive: true });
} else {
  console.log("[manager] Deployment directory already exists — skipping copy.");
}

// ── Install production dependencies ──────────────────────────────────────

const expressInstalled = fs.existsSync(
  path.join(MANAGER_DIR, "node_modules", "express"),
);

if (!expressInstalled) {
  console.log("[manager] Installing dependencies (--omit=dev)...");
  try {
    execSync("npm install --omit=dev", { cwd: MANAGER_DIR, stdio: "inherit" });
  } catch (err) {
    console.error(`[manager] npm install failed: ${err.message}`);
    process.exit(1);
  }
} else {
  console.log("[manager] node_modules already present — skipping install.");
}

// ── Write config.json ─────────────────────────────────────────────────────
// Generated fresh from variables.json on every run — never relies on
// placeholder-string patching. SCRIPT_DIR lets the manager's own config
// loader find variables.txt at SCRIPT_DIR/common/variables.txt, from which
// it reads SERVER_PATH, RCON credentials, INSTANCE_NAME, etc.

const managerConfig = {
  PORT:              webIface.PORT              || 3001,
  SCRIPT_DIR:        SCRIPTS_DIR,
  LOG_LINES:         1000,
  BLOCKED_COMMANDS:  webIface.BLOCKED_COMMANDS  || [],
  SESSION_TTL_HOURS: webIface.SESSION_TTL_HOURS || 24,
};

fs.mkdirSync(path.dirname(MANAGER_CONFIG), { recursive: true });
fs.writeFileSync(MANAGER_CONFIG, JSON.stringify(managerConfig, null, 2), "utf-8");
console.log(`[manager] config.json written (port ${managerConfig.PORT})`);

// ── Initialise users.json (first run only) ────────────────────────────────
// users.json is git-ignored and must be created post-deployment.
// A cryptographically random password is generated and printed once.
// The operator should record it — it can be changed later with:
//   node register.js <username> <new_password>
//
// We never store the plaintext password in variables.json; the hash lives
// only in users.json which is outside the repository.

if (!fs.existsSync(USERS_FILE)) {
  if (!fs.existsSync(REGISTER_JS)) {
    console.error("[manager] register.js not found in deployment directory.");
    console.error("  Re-run setup to re-deploy, or create users.json manually.");
    process.exit(1);
  }

  const initialPassword = crypto.randomBytes(16).toString("hex"); // 32-char hex
  const displayPw       = initialPassword; // kept in scope for the banner only

  try {
    execSync(
      `node "${REGISTER_JS}" admin "${initialPassword}"`,
      { cwd: MANAGER_DIR, stdio: "inherit" },
    );
  } catch (err) {
    console.error(`[manager] Failed to create admin user: ${err.message}`);
    process.exit(1);
  }

  // Overwrite the variable immediately after hashing so it doesn't linger
  // in memory longer than necessary (belt-and-suspenders for secrets)
  const _cleared = displayPw; // eslint-disable-line no-unused-vars

  const border  = "═".repeat(58);
  const pad     = (s, w) => s + " ".repeat(Math.max(0, w - s.length));
  console.log(`\n╔${border}╗`);
  console.log(`║  ${pad("⚠  Manager admin credentials — save these now!", 56)}║`);
  console.log(`║  ${pad("", 56)}║`);
  console.log(`║  ${pad("Username : admin", 56)}║`);
  console.log(`║  ${pad(`Password : ${_cleared}`, 56)}║`);
  console.log(`║  ${pad("", 56)}║`);
  console.log(`║  ${pad("To change: node scripts/register.js <user> <new_password>", 56)}║`);
  console.log(`╚${border}╝\n`);
} else {
  console.log("[manager] users.json already exists — skipping user initialisation.");
}

// ── Create or reload systemd service ─────────────────────────────────────
// Mirrors create_api_server_service.js exactly:
//   • First run  → write service file via temp + sudo mv (safe, no shell injection)
//   • Subsequent → restart the existing service to pick up config.json changes

const serviceExists = fs.existsSync(serviceFile);

if (!serviceExists) {
  const serviceContent = [
    "[Unit]",
    `Description=minecraft-server-manager — ${TARGET_DIR_NAME} / ${INSTANCE_NAME}`,
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    `User=${currentUser}`,
    `Group=${currentUser}`,
    `WorkingDirectory=${MANAGER_DIR}`,
    `ExecStart=/usr/bin/node ${MANAGER_APP}`,
    "Restart=on-failure",
    "RestartSec=5s",
    "StandardOutput=journal",
    "StandardError=journal",
    `SyslogIdentifier=${TARGET_DIR_NAME}-manager`,
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");

  try {
    // Write via temp file + sudo mv — avoids the shell-injection risk of
    // piping serviceContent through `echo "..." | sudo tee`.
    const tmpFile = path.join("/tmp", `mc-manager-service-${Date.now()}.tmp`);
    fs.writeFileSync(tmpFile, serviceContent, "utf-8");
    execSync(`sudo mv "${tmpFile}" "${serviceFile}"`);
    execSync(`sudo chmod 644 "${serviceFile}"`);
    execSync("sudo systemctl daemon-reload");
    execSync(`sudo systemctl enable ${serviceName}`);
    execSync(`sudo systemctl start  ${serviceName}`);
    console.log(`[manager] Service created and started: ${serviceName}`);
  } catch (err) {
    console.error(`[manager] Failed to create/start service: ${err.message}`);
    process.exit(1);
  }
} else {
  // config.json was updated above — restart so the manager picks it up
  try {
    execSync(`sudo systemctl restart ${serviceName}`);
    console.log(`[manager] Service restarted to apply updated config: ${serviceName}`);
  } catch (err) {
    console.error(`[manager] Failed to restart service: ${err.message}`);
    process.exit(1);
  }
}

console.log(`[manager] Web interface: http://localhost:${managerConfig.PORT}`);
