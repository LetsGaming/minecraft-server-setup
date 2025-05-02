const fs = require("fs");
const path = require("path");
const { exec } = require("child_process");
const { promisify } = require("util");

const loadVariables = require("../../common/loadVariables");
const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const CURRENT_INTERFACE_DIR = path.join(
  process.env.INTERFACE_SETUP_SCRIPT_DIR,
  "minecraft-server-manager"
);
const FINAL_INTERFACE_DIR = path.join(
  BASE_DIR,
  "scripts",
  MODPACK_NAME,
  "interface"
);

const execAsync = promisify(exec);

async function moveInterface() {
  try {
    // Ensure parent directory exists
    fs.mkdirSync(path.dirname(FINAL_INTERFACE_DIR), { recursive: true });

    // Remove existing final interface directory if it exists
    if (fs.existsSync(FINAL_INTERFACE_DIR)) {
      console.log(`Removing existing directory at ${FINAL_INTERFACE_DIR}`);
      await execAsync(`rm -rf "${FINAL_INTERFACE_DIR}"`);
    }

    // Move the interface
    console.log(
      `Moving interface from ${CURRENT_INTERFACE_DIR} to ${FINAL_INTERFACE_DIR}`
    );
    await execAsync(`mv "${CURRENT_INTERFACE_DIR}" "${FINAL_INTERFACE_DIR}"`);

    console.log("Interface moved successfully.");
  } catch (err) {
    console.error("Failed to move interface:", err);
    process.exit(1);
  }
}

moveInterface();
