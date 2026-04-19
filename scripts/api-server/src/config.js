"use strict";

const fs = require("fs");
const path = require("path");

// F-007: use shared parser instead of duplicating the loop
const { parseVarsFile } = require("./parseVars");

const VARS_FILE = path.resolve(
  __dirname,
  "..",
  "..",
  "common",
  "variables.txt",
);

function loadVars() {
  if (!fs.existsSync(VARS_FILE)) {
    console.error(`[api-server] variables.txt not found at ${VARS_FILE}`);
    process.exit(1);
  }
  return parseVarsFile(VARS_FILE);
}

const vars = loadVars();

module.exports = {
  PORT: parseInt(vars["API_SERVER_PORT"] || "3000", 10),
  API_KEY: vars["API_SERVER_KEY"] || "",
  SERVER_PATH: vars["SERVER_PATH"] || "",
  INSTANCE_NAME: vars["INSTANCE_NAME"] || "server",
  LINUX_USER: vars["USER"] || "minecraft",
  USE_RCON: vars["USE_RCON"] === "true",
  RCON_HOST: vars["RCON_HOST"] || "localhost",
  RCON_PORT: parseInt(vars["RCON_PORT"] || "25575", 10),
  RCON_PASSWORD: vars["RCON_PASSWORD"] || "",
  BACKUPS_PATH: vars["BACKUPS_PATH"] || "",
  // Script root is two levels up from src/ (i.e. scripts/<instance>/)
  INSTANCE_SCRIPTS_DIR: path.resolve(__dirname, "..", ".."),
};
