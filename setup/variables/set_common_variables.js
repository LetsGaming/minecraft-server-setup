const path = require("path");
const fs = require("fs");
const loadVariables = require("../common/loadVariables");

// Load variables
const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

// Construct paths
const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const serverPath = path.join(BASE_DIR, MODPACK_NAME);
const variablesFilePath = path.resolve(__dirname, "..", "scripts", "common", "variables.txt");

// Prepare content
const variablesContent = [
  `USER="${process.env.USER}"`,
  `MODPACK_NAME="${MODPACK_NAME}"`,
  `SERVER_PATH="${serverPath}"`
].join("\n");

// Write to file
fs.writeFileSync(variablesFilePath, variablesContent);

console.log(`Variables written to ${variablesFilePath}`);