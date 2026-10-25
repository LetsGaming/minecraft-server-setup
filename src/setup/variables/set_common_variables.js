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
const serverPath = path.join(BASE_DIR, "instances", INSTANCE_NAME);
const variablesFilePath = path.resolve(
  __dirname,
  "..",
  "..",
  "scripts",
  "common",
  "variables.txt",
);

let backupsPath = BACKUPS.BACKUPS_PATH;
if (backupsPath === "none") {
  backupsPath = path.join(BASE_DIR, "backups", INSTANCE_NAME);
}

// variables.txt is consumed by the bash runtime via `source`, so any value
// embedded in a KEY="value" line is interpreted by the shell. Without escaping,
// a value containing " ` $ or \ becomes live shell code at source time
// (e.g. an RCON password of `x"; rm -rf ~; echo "` would execute). We keep the
// outer double-quote format (the api-server parser and `cut -d'"'` consumers
// depend on it) and backslash-escape exactly the four characters that are
// special inside a double-quoted shell string. Newlines are collapsed since a
// KEY="value" line must stay on one line.
function shDquote(value) {
  return String(value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\$/g, "\\$")
    .replace(/`/g, "\\`")
    .replace(/\r?\n/g, " ");
}
const q = (v) => `"${shDquote(v)}"`;

// Build variables content
const lines = [
  // Core
  `USER=${q(process.env.USER)}`,
  `INSTANCE_NAME=${q(INSTANCE_NAME)}`,
  `SERVER_PATH=${q(serverPath)}`,
  // Backups
  `BACKUPS_PATH=${q(backupsPath)}`,
  `COMPRESSION_LEVEL=${q(BACKUPS.COMPRESSION_LEVEL)}`,
  `MAX_STORAGE_GB=${q(BACKUPS.MAX_STORAGE_GB)}`,
  `DO_GENERATION_BACKUPS=${q(BACKUPS.DO_GENERATION_BACKUPS)}`,
  `MAX_HOURLY_BACKUPS=${q(BACKUPS.MAX_HOURLY_BACKUPS)}`,
  `MAX_DAILY_BACKUPS=${q(BACKUPS.MAX_DAILY_BACKUPS)}`,
  `MAX_WEEKLY_BACKUPS=${q(BACKUPS.MAX_WEEKLY_BACKUPS)}`,
  `MAX_MONTHLY_BACKUPS=${q(BACKUPS.MAX_MONTHLY_BACKUPS)}`,
  `MAX_UPDATE_BACKUPS=${q(BACKUPS.MAX_UPDATE_BACKUPS ?? 5)}`,
  // RCON
  `USE_RCON=${q(serverControl.USE_RCON || false)}`,
  `RCON_HOST=${q(serverControl.RCON_HOST || "localhost")}`,
  `RCON_PORT=${q(serverControl.RCON_PORT || 25575)}`,
  `RCON_PASSWORD=${q(serverControl.RCON_PASSWORD || "")}`,
  // Webhooks
  `WEBHOOK_URL=${q(notifications.WEBHOOK_URL || "")}`,
  `WEBHOOK_EVENTS=${q((notifications.WEBHOOK_EVENTS || []).join(" "))}`,
  // Restart schedule
  `RESTART_ENABLED=${q(restartSchedule.ENABLED || false)}`,
  `RESTART_INTERVAL_HOURS=${q(restartSchedule.INTERVAL_HOURS || 12)}`,
  `RESTART_SKIP_IF_EMPTY=${q(restartSchedule.SKIP_IF_EMPTY !== false)}`,
  `RESTART_WARN_SECONDS=${q(restartSchedule.WARN_SECONDS || 30)}`,
  // API server (Discord bot integration)
  `API_SERVER_ENABLED=${q(apiServer.ENABLED || false)}`,
  `API_SERVER_PORT=${q(apiServer.PORT || 3000)}`,
  `API_SERVER_KEY=${q(apiServer.API_KEY || "")}`,
];

// Optional backup tuning keys are written only when set; the shell scripts
// default the rest, so an older variables.txt keeps working unchanged.
const OPTIONAL_BACKUP_KEYS = [
  "MAX_CUSTOM_BACKUPS",
  "BACKUP_HOURLY_LEVEL",
  "BACKUP_ARCHIVE_LEVEL",
  "BACKUP_ZSTD_THREADS",
  "BACKUP_STAGING_MODE",
  "BACKUP_FOLLOW_SYMLINKS",
  "BACKUP_EXTRA_EXCLUDES",
  "BACKUP_SPACE_MARGIN_PCT",
  "BACKUP_TIMEOUT_MINUTES",
  "BACKUP_SKIP_ALERT_AFTER",
  "BACKUP_ARCHIVE_MAX_ATTEMPTS",
  "BACKUP_LOG_MAX_MB",
  "RESTORE_KEEP_OLD",
  "RESTORE_KEEP_OLD_DAYS",
  "RESTORE_CARRY_OVER",
];
for (const key of OPTIONAL_BACKUP_KEYS) {
  if (BACKUPS[key] !== undefined) lines.push(`${key}=${q(BACKUPS[key])}`);
}

// The optional mirror: written only when it is switched on, so an install that
// never heard of it gets the same variables.txt as before. mirror.sh setup keeps
// its own managed block in the same file; whichever comes last wins.
const MIRROR = vars.MIRROR || {};
if (MIRROR.ENABLED === true) {
  const MIRROR_KEYS = {
    ROLE: "MIRROR_ROLE",
    REMOTE: "MIRROR_REMOTE",
    SSH_PORT: "MIRROR_SSH_PORT",
    SOURCE_MODE: "MIRROR_SOURCE_MODE",
    EXPORT_AT: "MIRROR_EXPORT_AT",
    PULL_AT: "MIRROR_PULL_AT",
    BWLIMIT_KIB: "MIRROR_BWLIMIT_KIB",
    PARITY: "MIRROR_PARITY",
    MIN_REGION_RATIO_PCT: "MIRROR_MIN_REGION_RATIO_PCT",
    MAX_SNAPSHOT_GB: "MIRROR_MAX_SNAPSHOT_GB",
    KEEP_SNAPSHOTS: "MIRROR_KEEP_SNAPSHOTS",
  };
  lines.push(`MIRROR_ENABLED=${q(true)}`);
  for (const [key, name] of Object.entries(MIRROR_KEYS)) {
    if (MIRROR[key] !== undefined) lines.push(`${name}=${q(MIRROR[key])}`);
  }
  if (Array.isArray(MIRROR.DIMS)) lines.push(`MIRROR_DIMS=${q(MIRROR.DIMS.join(" "))}`);
}

const variablesContent = lines.join("\n");

// Ensure directory exists
const dir = path.dirname(variablesFilePath);
if (!fs.existsSync(dir)) {
  fs.mkdirSync(dir, { recursive: true });
}

fs.writeFileSync(variablesFilePath, variablesContent, { mode: 0o600 });
// Re-assert mode in case the file pre-existed with looser perms (writeFileSync
// does not chmod an existing file).
fs.chmodSync(variablesFilePath, 0o600);
console.log(`Variables written to ${variablesFilePath}`);
