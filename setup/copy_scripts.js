const fs = require('fs');
const path = require('path');
const loadVariables = require('./common/loadVariables');

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

// Zielverzeichnis für die Scripts (z. B. /home/minecraft/instances/<modpack>/scripts)
const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', MODPACK_NAME);

// Quelle der Scripts liegt im Projekt-Root unter /scripts
const sourceDir = path.resolve(__dirname, '..', 'scripts');

// Sicherstellen, dass das Zielverzeichnis existiert
fs.mkdirSync(SCRIPTS_DIR, { recursive: true });

// Scripts kopieren
fs.readdirSync(sourceDir).forEach(file => {
  const sourceFile = path.join(sourceDir, file);
  const targetFile = path.join(SCRIPTS_DIR, file);
  fs.copyFileSync(sourceFile, targetFile);
});

console.log('Scripts copied successfully.');
