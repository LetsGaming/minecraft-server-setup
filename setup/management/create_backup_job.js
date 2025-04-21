const fs = require("fs");
const { execSync } = require("child_process");
const path = require("path");
const loadVariables = require("../common/loadVariables");

try {
  // Load variables from JSON
  const vars = loadVariables();
  const { TARGET_DIR_NAME, MODPACK_NAME } = vars;
  const BASE_DIR = path.join(process.env.HOME, TARGET_DIR_NAME);
  const SCRIPTS_DIR = path.join(BASE_DIR, "scripts", MODPACK_NAME);

  // Define backup paths
  const backupDir = path.join(SCRIPTS_DIR, "backup");
  const automationDir = path.join(backupDir, "automation");
  const logsDir = path.join(backupDir, "logs");

  const runBackupPath = path.resolve(automationDir, "run_backup.sh");
  const cleanupPath = path.resolve(automationDir, "cleanup_archives.sh");

  if (!fs.existsSync(runBackupPath)) {
    throw new Error(`Backup wrapper script not found: ${runBackupPath}`);
  }
  if (!fs.existsSync(cleanupPath)) {
    throw new Error(`Cleanup script not found: ${cleanupPath}`);
  }

  // Ensure log directory exists
  if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
  }

  // Define cron job commands
  const hourlyBackupCmd = `0 * * * * bash ${runBackupPath} >> ${logsDir}/run_backup.log 2>&1`;
  const cleanupCmd = `10 * * * * bash ${cleanupPath} >> ${logsDir}/cleanup.log 2>&1`;

  // Get existing crontab
  let existingCrontab = "";
  try {
    existingCrontab = execSync("crontab -l", { encoding: "utf-8" });
  } catch (err) {
    if (err.status !== 1) throw err; // status 1 = no crontab for user
  }

  const newJobs = [];

  // Add hourly backup if not present
  if (!existingCrontab.includes(runBackupPath)) {
    newJobs.push(hourlyBackupCmd);
    console.log("Added hourly backup cronjob.");
  } else {
    console.log("Hourly backup cronjob already exists. Skipping.");
  }

  // Add cleanup job if not present
  if (!existingCrontab.includes(cleanupPath)) {
    newJobs.push(cleanupCmd);
    console.log("Added cleanup cronjob.");
  } else {
    console.log("Cleanup cronjob already exists. Skipping.");
  }

  if (newJobs.length > 0) {
    const newCrontab = `${existingCrontab.trim()}\n${newJobs.join("\n")}\n`;
    const tmpFile = "/tmp/cronjob.tmp";

    fs.writeFileSync(tmpFile, newCrontab);
    execSync(`crontab ${tmpFile}`);
    fs.unlinkSync(tmpFile);
  } else {
    console.log("No new cronjobs needed.");
  }

} catch (err) {
  console.error("Error setting up cronjobs:", err.message);
  process.exit(1);
}
