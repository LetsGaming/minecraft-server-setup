const path = require("path");
const fs = require("fs");

const rawConfig = require("./config.json");

// ── Parse variables.txt from the scripts directory ──
function loadServerVars(scriptDir) {
  const varsFile = path.join(scriptDir, "common", "variables.txt");
  const vars = {};
  if (!fs.existsSync(varsFile)) {
    console.warn(`[config] variables.txt not found at ${varsFile} — using config.json values only`);
    return vars;
  }
  const content = fs.readFileSync(varsFile, "utf-8");
  for (const line of content.split(/\r?\n/)) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    vars[match[1]] = value;
  }
  return vars;
}

const SCRIPT_DIR = rawConfig.SCRIPT_DIR;
const serverVars = loadServerVars(SCRIPT_DIR);

// ── Build resolved config ──
const config = {
  PORT: rawConfig.PORT || 3000,
  LOG_LINES: rawConfig.LOG_LINES || 1000,
  BLOCKED_COMMANDS: rawConfig.BLOCKED_COMMANDS || [],
  SESSION_TTL_HOURS: rawConfig.SESSION_TTL_HOURS || 24,

  // From variables.txt (with config.json fallback)
  SCRIPT_DIR,
  USER: serverVars.USER || rawConfig.USER || process.env.USER,
  INSTANCE_NAME: serverVars.INSTANCE_NAME || rawConfig.INSTANCE_NAME || "server",
  SERVER_PATH: serverVars.SERVER_PATH || rawConfig.SERVER_PATH || "",
  BACKUPS_PATH: serverVars.BACKUPS_PATH || "",

  // RCON config (from variables.txt)
  USE_RCON: serverVars.USE_RCON === "true",
  RCON_HOST: serverVars.RCON_HOST || "localhost",
  RCON_PORT: parseInt(serverVars.RCON_PORT || "25575", 10),
  RCON_PASSWORD: serverVars.RCON_PASSWORD || "",
};

// ── Script paths ──
config.SCRIPTS = {
  status:        path.join(SCRIPT_DIR, "misc", "status.sh"),
  start:         path.join(SCRIPT_DIR, "start.sh"),
  shutdown:      path.join(SCRIPT_DIR, "shutdown.sh"),
  restart:       path.join(SCRIPT_DIR, "restart.sh"),
  smartRestart:  path.join(SCRIPT_DIR, "smart_restart.sh"),
  rollback:      path.join(SCRIPT_DIR, "rollback.sh"),
  backup:        path.join(SCRIPT_DIR, "backup", "backup.sh"),
  restore:       path.join(SCRIPT_DIR, "backup", "restore.sh"),
};

// Validate critical paths
if (!config.SERVER_PATH) {
  console.warn("[config] SERVER_PATH is not set. Some features may not work.");
}

module.exports = config;
