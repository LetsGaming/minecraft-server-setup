const fs = require("fs");
const { execSync } = require("child_process");
const path = require("path");
const loadVariables = require("../common/loadVariables");

try {
  const vars = loadVariables();
  const { TARGET_DIR_NAME, INSTANCE_NAME, RESTART_SCHEDULE } = vars;

  if (!RESTART_SCHEDULE || !RESTART_SCHEDULE.ENABLED) {
    console.log("Scheduled restarts not enabled. Skipping.");
    process.exit(0);
  }

  const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
  const SCRIPTS_DIR = path.join(BASE_DIR, "scripts", INSTANCE_NAME);
  const restartScript = path.resolve(SCRIPTS_DIR, "backup", "automation", "scheduled_restart.sh");
  const logsDir = path.join(SCRIPTS_DIR, "backup", "logs");

  if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
  }

  const intervalHours = RESTART_SCHEDULE.INTERVAL_HOURS || 12;

  // Build cron expression: every N hours
  const cronExpr = `0 */${intervalHours} * * *`;
  const cronCmd = `${cronExpr} bash ${restartScript} >> ${logsDir}/restart.log 2>&1`;

  // Get existing crontab
  let existingCrontab = "";
  try {
    existingCrontab = execSync("crontab -l", { encoding: "utf-8" });
  } catch (err) {
    if (err.status !== 1) throw err;
  }

  if (!existingCrontab.includes(restartScript)) {
    const newCrontab = `${existingCrontab.trim()}\n${cronCmd}\n`;
    const tmpFile = "/tmp/cronjob-restart.tmp";
    fs.writeFileSync(tmpFile, newCrontab);
    execSync(`crontab ${tmpFile}`);
    fs.unlinkSync(tmpFile);
    console.log(`Added scheduled restart cronjob (every ${intervalHours}h).`);
  } else {
    console.log("Scheduled restart cronjob already exists. Skipping.");
  }
} catch (err) {
  console.error("Error setting up restart cronjob:", err.message);
  process.exit(1);
}
