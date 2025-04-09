const fs = require('fs');
const path = require('path');

// Ensure required variables are defined
const TARGET_DIR_NAME = process.env.TARGET_DIR_NAME;
const MODPACK_NAME = process.env.MODPACK_NAME;

if (!TARGET_DIR_NAME || !MODPACK_NAME) {
  throw new Error('Missing required environment variables: TARGET_DIR_NAME or MODPACK_NAME');
}

const BASE_DIR = path.join(process.env.HOME, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', MODPACK_NAME);

// Copy scripts into the target directory
const sourceDir = path.join(__dirname, 'scripts');
fs.readdirSync(sourceDir).forEach(file => {
  const sourceFile = path.join(sourceDir, file);
  const targetFile = path.join(SCRIPTS_DIR, file);
  fs.copyFileSync(sourceFile, targetFile);
});

console.log('Scripts copied successfully.');
