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

  // Define what the cronjob should do
  const scriptPath = path.resolve(SCRIPTS_DIR, "backup", "backup.sh");

  if (!fs.existsSync(scriptPath)) {
    throw new Error(`Script file not found at: ${scriptPath}`);
  }

  // Define the cronjob line (once per hour)
  const cronCommand = `0 * * * * ${scriptPath} >> ${path.resolve(
    __dirname,
    "cron.log"
  )} 2>&1`;

  // Get existing crontab (if any)
  let existingCrontab = "";
  try {
    existingCrontab = execSync("crontab -l", { encoding: "utf-8" });
  } catch (err) {
    if (err.status !== 1) throw err; // ignore "no crontab for user", treat as empty
  }

  // Avoid duplicate entry
  if (existingCrontab.includes(scriptPath)) {
    console.log("Cronjob already exists. Skipping.");
  } else {
    const newCrontab = `${existingCrontab.trim()}\n${cronCommand}\n`;
    const tmpFile = "/tmp/cronjob.tmp";

    fs.writeFileSync(tmpFile, newCrontab);
    execSync(`crontab ${tmpFile}`);
    fs.unlinkSync(tmpFile);

    console.log("Cronjob added successfully.");
  }
} catch (err) {
  console.error("Error setting up cronjob:", err.message);
  process.exit(1);
}
