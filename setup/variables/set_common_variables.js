const path = require("path");
const fs = require("fs");
const loadVariables = require("../common/loadVariables");

const vars = loadVariables();
const { TARGET_DIR_NAME, INSTANCE_NAME, BACKUPS } = vars;

// Optional sections with defaults
const serverControl = vars.SERVER_CONTROL || {};
const notifications = vars.NOTIFICATIONS || {};
const restartSchedule = vars.RESTART_SCHEDULE || {};
const apiServer = vars.API_SERVER || {};

// Construct paths
const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const serverPath = path.join(BASE_DIR, INSTANCE_NAME);
const variablesFilePath = path.resolve(
  __dirname, "..", "..", "scripts", "common", "variables.txt"
);

let backupsPath = BACKUPS.BACKUPS_PATH;
if (backupsPath === "none") {
  backupsPath = path.join(BASE_DIR, "backups", INSTANCE_NAME);
}

// Build variables content
const lines = [
  // Core
  `USER="${process.env.USER}"`,
  `INSTANCE_NAME="${INSTANCE_NAME}"`,
  `SERVER_PATH="${serverPath}"`,
  // Backups
  `BACKUPS_PATH="${backupsPath}"`,
  `COMPRESSION_LEVEL="${BACKUPS.COMPRESSION_LEVEL}"`,
  `MAX_STORAGE_GB="${BACKUPS.MAX_STORAGE_GB}"`,
  `DO_GENERATION_BACKUPS="${BACKUPS.DO_GENERATION_BACKUPS}"`,
  `MAX_HOURLY_BACKUPS="${BACKUPS.MAX_HOURLY_BACKUPS}"`,
  `MAX_DAILY_BACKUPS="${BACKUPS.MAX_DAILY_BACKUPS}"`,
  `MAX_WEEKLY_BACKUPS="${BACKUPS.MAX_WEEKLY_BACKUPS}"`,
  `MAX_MONTHLY_BACKUPS="${BACKUPS.MAX_MONTHLY_BACKUPS}"`,
  // RCON
  `USE_RCON="${serverControl.USE_RCON || false}"`,
  `RCON_HOST="${serverControl.RCON_HOST || "localhost"}"`,
  `RCON_PORT="${serverControl.RCON_PORT || 25575}"`,
  `RCON_PASSWORD="${serverControl.RCON_PASSWORD || ""}"`,
  // Webhooks
  `WEBHOOK_URL="${notifications.WEBHOOK_URL || ""}"`,
  `WEBHOOK_EVENTS="${(notifications.WEBHOOK_EVENTS || []).join(" ")}"`,
  // Restart schedule
  `RESTART_ENABLED="${restartSchedule.ENABLED || false}"`,
  `RESTART_INTERVAL_HOURS="${restartSchedule.INTERVAL_HOURS || 12}"`,
  `RESTART_SKIP_IF_EMPTY="${restartSchedule.SKIP_IF_EMPTY !== false}"`,
  `RESTART_WARN_SECONDS="${restartSchedule.WARN_SECONDS || 30}"`,
  // API server (Discord bot integration)
  `API_SERVER_ENABLED="${apiServer.ENABLED || false}"`,
  `API_SERVER_PORT="${apiServer.PORT || 3000}"`,
  `API_SERVER_KEY="${apiServer.API_KEY || ''}"`,
];

const variablesContent = lines.join("\n");

// Ensure directory exists
const dir = path.dirname(variablesFilePath);
if (!fs.existsSync(dir)) {
  fs.mkdirSync(dir, { recursive: true });
}

fs.writeFileSync(variablesFilePath, variablesContent);
console.log(`Variables written to ${variablesFilePath}`);
