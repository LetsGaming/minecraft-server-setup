const fs = require('fs');
const path = require('path');
const loadVariables = require('./common/loadVariables');

// Load the existing variables
const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

// Zielverzeichnis für die Scripts (z. B. /home/minecraft/instances/<modpack>/scripts)
const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', MODPACK_NAME);

// Quelle der Scripts liegt im Projekt-Root unter /scripts
const sourceDir = path.resolve(__dirname, '..', 'scripts');

// Schreiben des MODPACK_NAME in die variables.txt im /scripts/common Verzeichnis
const variablesFilePath = path.join(sourceDir, 'common', 'variables.txt');

// Erstellen oder Überschreiben der variables.txt Datei
const variablesContent = `MODPACK_NAME="${MODPACK_NAME}"\n`;
fs.writeFileSync(variablesFilePath, variablesContent, { flag: 'w' });

// Sicherstellen, dass das Zielverzeichnis existiert
fs.mkdirSync(SCRIPTS_DIR, { recursive: true });

// Scripts kopieren
fs.readdirSync(sourceDir).forEach(file => {
  const sourceFile = path.join(sourceDir, file);
  const targetFile = path.join(SCRIPTS_DIR, file);
  
  // Prüfen, ob es sich um eine Datei oder ein Verzeichnis handelt
  const stats = fs.statSync(sourceFile);
  if (stats.isDirectory()) {
    // Falls es ein Verzeichnis ist, es rekursiv kopieren
    fs.cpSync(sourceFile, targetFile, { recursive: true });
  } else if (stats.isFile()) {
    // Falls es eine Datei ist, sie kopieren
    fs.copyFileSync(sourceFile, targetFile);
  }
});

console.log('Scripts copied successfully and MODPACK_NAME written to variables.txt.');
