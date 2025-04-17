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
  const backupDir = path.join(SCRIPTS_DIR, "backups");
  const scriptPath = path.resolve(backupDir, "backup.sh");

  if (!fs.existsSync(scriptPath)) {
    throw new Error(`Script file not found at: ${scriptPath}`);
  }

  // Define cron job commands
  const hourlyBackupCmd = `0 * * * * bash ${scriptPath} >> ${backupDir}/backup.log 2>&1`;
  const archiveBackupCmd = `0 1 * * * bash ${scriptPath} --archive >> ${backupDir}/archive_backup.log 2>&1`;

  // Get existing crontab
  let existingCrontab = "";
  try {
    existingCrontab = execSync("crontab -l", { encoding: "utf-8" });
  } catch (err) {
    if (err.status !== 1) throw err; // status 1 = no crontab for user
  }

  const newJobs = [];

  // Add hourly backup if not present
  if (!existingCrontab.includes(`${scriptPath} >>`)) {
    newJobs.push(hourlyBackupCmd);
    console.log("Added hourly backup cronjob.");
  } else {
    console.log("Hourly backup cronjob already exists. Skipping.");
  }

  // Add archive backup if not present
  if (!existingCrontab.includes(`${scriptPath} --archive`)) {
    newJobs.push(archiveBackupCmd);
    console.log("Added archive backup cronjob.");
  } else {
    console.log("Archive backup cronjob already exists. Skipping.");
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
