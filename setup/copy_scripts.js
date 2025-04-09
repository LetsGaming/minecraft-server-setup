const fs = require('fs');
const path = require('path');
const loadVariables = require('../common/loadVariables');

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', MODPACK_NAME);

// Copy scripts into the target directory
const sourceDir = path.join(__dirname, 'scripts');
fs.readdirSync(sourceDir).forEach(file => {
  const sourceFile = path.join(sourceDir, file);
  const targetFile = path.join(SCRIPTS_DIR, file);
  fs.copyFileSync(sourceFile, targetFile);
});

console.log('Scripts copied successfully.');
