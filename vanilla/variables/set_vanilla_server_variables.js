const path = require("path");
const fs = require("fs");
const loadVariables = require("../../setup/common/loadVariables");

const {
  TARGET_DIR_NAME,
  INSTANCE_NAME,
  JAVA: {
    SERVER: { VANILLA },
  },
} = loadVariables();

const MODPACK_DIR = path.join(
  process.env.MAIN_DIR,
  TARGET_DIR_NAME,
  INSTANCE_NAME
);
const variablesTxtPath = path.join(MODPACK_DIR, "variables.txt");

// Read existing content
let variablesTxtContent = "";
if (fs.existsSync(variablesTxtPath)) {
  variablesTxtContent = fs.readFileSync(variablesTxtPath, "utf-8");
}

// Parse existing variables
const variables = Object.fromEntries(
  variablesTxtContent
    .split("\n")
    .filter((line) => line.includes("="))
    .map((line) => line.split("="))
    .map(([key, value]) => [key.trim(), value.trim()])
);

// Prepare new values (overwrite or add)
variables["USE_FABRIC"] = VANILLA;
variables["WAIT_FOR_USER_INPUT"] = "true";
variables["ADDITIONAL_ARGS"] = "-Dlog4j2.formatMsgNoLookups=true";
variables["RESTART"] = "true";

// Reconstruct and write back
const newContent = Object.entries(variables)
  .map(([key, value]) => `${key}=${value}`)
  .join("\n");

fs.writeFileSync(variablesTxtPath, newContent, "utf-8");
