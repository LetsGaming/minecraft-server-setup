const fs = require('fs');
const path = require('path');
const loadVariables = require('./common/loadVariables');

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.HOME, TARGET_DIR_NAME);
const MODPACK_DIR = path.join(BASE_DIR, MODPACK_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', MODPACK_NAME);

fs.mkdirSync(BASE_DIR, { recursive: true });
fs.mkdirSync(MODPACK_DIR, { recursive: true });
fs.mkdirSync(SCRIPTS_DIR, { recursive: true });

console.log('Directories created successfully.');
