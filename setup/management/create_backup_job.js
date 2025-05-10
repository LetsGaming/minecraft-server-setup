const fs = require("fs");
const { execSync } = require("child_process");
const path = require("path");
const loadVariables = require("../common/loadVariables");

try {
  // Load variables from JSON
  const vars = loadVariables();
  const { TARGET_DIR_NAME, INSTANCE_NAME } = vars;
  const BASE_DIR = path.join(process.env.HOME, TARGET_DIR_NAME);
  const SCRIPTS_DIR = path.join(BASE_DIR, "scripts", INSTANCE_NAME);

  // Define backup paths
  const backupDir = path.join(SCRIPTS_DIR, "backup");
  const automationDir = path.join(backupDir, "automation");
  const logsDir = path.join(backupDir, "logs");

  const runBackupPath = path.resolve(automationDir, "run_backup.sh");

  if (!fs.existsSync(runBackupPath)) {
    throw new Error(`Backup wrapper script not found: ${runBackupPath}`);
  }

  // Ensure log directory exists
  if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
  }

  // Define cron job command
  const hourlyBackupCmd = `0 * * * * bash ${runBackupPath} >> ${logsDir}/backup.log 2>&1`;

  // Get existing crontab
  let existingCrontab = "";
  try {
    existingCrontab = execSync("crontab -l", { encoding: "utf-8" });
  } catch (err) {
    if (err.status !== 1) throw err; // status 1 = no crontab for user
  }

  // Add hourly backup if not present
  if (!existingCrontab.includes(runBackupPath)) {
    const newCrontab = `${existingCrontab.trim()}\n${hourlyBackupCmd}\n`;
    const tmpFile = "/tmp/cronjob.tmp";

    fs.writeFileSync(tmpFile, newCrontab);
    execSync(`crontab ${tmpFile}`);
    fs.unlinkSync(tmpFile);
    console.log("Added hourly backup cronjob.");
  } else {
    console.log("Hourly backup cronjob already exists. Skipping.");
  }
} catch (err) {
  console.error("Error setting up cronjob:", err.message);
  process.exit(1);
}
