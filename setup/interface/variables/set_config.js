const fs = require("fs");
const path = require("path");
const loadVariables = require("../../common/loadVariables");

const { INSTANCE_NAME, TARGET_DIR_NAME } = loadVariables();
const currentUser = process.env.USER;
const INTERFACE_DIR = process.env.INTERFACE_SETUP_SCRIPT_DIR;
const MANAGER_CONFIG = path.join(INTERFACE_DIR, "minecraft-server-manager", "src", "config", "config.json");

if (!fs.existsSync(MANAGER_CONFIG)) {
  console.error("Minecraft Server Manager config.json not found.");
  process.exit(1);
}

const manager_config = JSON.parse(fs.readFileSync(MANAGER_CONFIG, "utf-8"));

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPT_DIR = path.join(BASE_DIR, "scripts", INSTANCE_NAME);
const SERVER_PATH = path.join(BASE_DIR, INSTANCE_NAME);

// Replace values in config if they match placeholders
let changed = false;

if (manager_config.USER === "your_username") {
  manager_config.USER = currentUser;
  changed = true;
}

if (manager_config.INSTANCE_NAME === "your_INSTANCE_NAME") {
  manager_config.INSTANCE_NAME = INSTANCE_NAME;
  changed = true;
}

if (manager_config.SCRIPT_DIR === "/path/to/your/scripts") {
  manager_config.SCRIPT_DIR = SCRIPT_DIR;
  changed = true;
}

if (manager_config.SERVER_PATH === "/path/to/your/minecraft/server") {
  manager_config.SERVER_PATH = SERVER_PATH;
  changed = true;
}

// Write updated config back to file if any changes were made
if (changed) {
  fs.writeFileSync(MANAGER_CONFIG, JSON.stringify(manager_config, null, 2), "utf-8");
  console.log("Updated config.json with actual values.");
} else {
  console.log("No updates needed for config.json.");
}
