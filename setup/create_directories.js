const fs = require('fs');
const path = require('path');

// Ensure required variables are defined
const TARGET_DIR_NAME = process.env.TARGET_DIR_NAME;
const MODPACK_NAME = process.env.MODPACK_NAME;

if (!TARGET_DIR_NAME || !MODPACK_NAME) {
  throw new Error('Missing required environment variables: TARGET_DIR_NAME or MODPACK_NAME');
}

const BASE_DIR = path.join(process.env.HOME, TARGET_DIR_NAME);
const MODPACK_DIR = path.join(BASE_DIR, MODPACK_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', MODPACK_NAME);

// Create base directory and modpack directory
fs.mkdirSync(BASE_DIR, { recursive: true });
fs.mkdirSync(MODPACK_DIR, { recursive: true });

// Create scripts directories
fs.mkdirSync(SCRIPTS_DIR, { recursive: true });

console.log('Directories created successfully.');
