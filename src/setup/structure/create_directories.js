const fs = require("fs");
const path = require("path");
const loadVariables = require("../common/loadVariables");

const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.HOME, TARGET_DIR_NAME);
const INSTANCE_DIR = path.join(BASE_DIR, "instances", INSTANCE_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, "scripts", INSTANCE_NAME);
const SERVICES_DIR = path.join(BASE_DIR, "services");

fs.mkdirSync(BASE_DIR, { recursive: true });
fs.mkdirSync(INSTANCE_DIR, { recursive: true });
fs.mkdirSync(SCRIPTS_DIR, { recursive: true });
fs.mkdirSync(SERVICES_DIR, { recursive: true });

console.log("Directories created successfully.");
