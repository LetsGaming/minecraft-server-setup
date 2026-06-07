const { execFile } = require("child_process");
const path = require("path");
const fs = require("fs");
const loadVariables = require("../common/loadVariables");

const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const serverScriptsPath = path.join(BASE_DIR, "scripts", INSTANCE_NAME);
const scriptPath = path.join(serverScriptsPath, "start.sh");

// Get the current user
const currentUser = process.env.USER;

// Check if the start.sh script exists
if (!fs.existsSync(scriptPath)) {
  console.error(`start.sh script not found at ${scriptPath}`);
  return;
}

// Wrap the start.sh script execution in a screen session, run as the current user
const screenCommand = `sudo -u ${currentUser} screen -S "${INSTANCE_NAME}" -dm bash ${scriptPath}`;

execFile("bash", ["-c", screenCommand], (error, stdout, stderr) => {
  if (error) {
    console.error(`Error executing screen command: ${error.message}`);
    return;
  }
  if (stderr) {
    console.error(`stderr: ${stderr}`);
  }
  console.log(`stdout:\n${stdout}`);
});
