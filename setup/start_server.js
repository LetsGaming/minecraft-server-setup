const { execFile } = require("child_process");
const path = require("path");
const loadVariables = require("./common/loadVariables");

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const serverScriptsPath = path.join(BASE_DIR, "scripts", MODPACK_NAME);
const scriptPath = path.join(serverScriptsPath, "start.sh");

// Wrap the start.sh script execution in a screen session
const screenCommand = `screen -S "${MODPACK_NAME}" -dm bash ${scriptPath}`;

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
