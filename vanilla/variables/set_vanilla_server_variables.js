const path = require("path");
const fs = require("fs");
const os = require("os");
const loadVariables = require("../../setup/common/loadVariables");

const {
  TARGET_DIR_NAME,
  INSTANCE_NAME,
  JAVA
} = loadVariables();

const VANILLA = JAVA.SERVER.VANILLA.USE_FABRIC ? "true" : "false";

const MODPACK_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME, INSTANCE_NAME);
const variablesTxtPath = path.join(MODPACK_DIR, "variables.txt");

// Read existing content line by line
let lines = [];
if (fs.existsSync(variablesTxtPath)) {
  const raw = fs.readFileSync(variablesTxtPath, "utf-8");
  lines = raw.split(/\r?\n/);
}

// Preserve all lines that are not targeted keys
const preservedLines = [];
const keysToReplace = new Set([
  "USE_FABRIC",
  "WAIT_FOR_USER_INPUT",
  "ADDITIONAL_ARGS",
  "RESTART"
]);

for (const line of lines) {
  const trimmed = line.trim();
  if (
    !trimmed ||
    trimmed.startsWith("#") ||
    !trimmed.includes("=")
  ) {
    preservedLines.push(line);
    continue;
  }

  const [key] = trimmed.split("=", 1);
  if (!keysToReplace.has(key.trim())) {
    preservedLines.push(line);
  }
}

// Append updated or new settings
const updates = {
  USE_FABRIC: VANILLA,
  WAIT_FOR_USER_INPUT: "true",
  ADDITIONAL_ARGS: "-Dlog4j2.formatMsgNoLookups=true",
  RESTART: "true"
};

for (const [key, value] of Object.entries(updates)) {
  preservedLines.push(`${key}=${value}`);
}

// Final write
fs.writeFileSync(variablesTxtPath, preservedLines.join(os.EOL), "utf-8");
