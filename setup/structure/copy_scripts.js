'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const loadVariables = require('../common/loadVariables');

const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', INSTANCE_NAME);
const sourceDir = path.resolve(__dirname, '..', '..', 'scripts');

fs.mkdirSync(SCRIPTS_DIR, { recursive: true });

// Copy all scripts
fs.readdirSync(sourceDir).forEach(file => {
  const src = path.join(sourceDir, file);
  const dst = path.join(SCRIPTS_DIR, file);
  const stats = fs.statSync(src);
  if (stats.isDirectory()) {
    fs.cpSync(src, dst, { recursive: true });
  } else if (stats.isFile()) {
    fs.copyFileSync(src, dst);
  }
});

console.log('Scripts copied successfully.');

// Install npm dependencies for self-contained subdirectories.
// Each subdirectory with its own package.json manages its own node_modules so
// the scripts work after deployment without the setup project being present.
const npmDirs = [
  path.join(SCRIPTS_DIR, 'update'),
  path.join(SCRIPTS_DIR, 'api-server'),
];

for (const dir of npmDirs) {
  if (fs.existsSync(path.join(dir, 'package.json'))) {
    const label = path.relative(BASE_DIR, dir);
    console.log(`Installing npm dependencies in ${label}...`);
    try {
      execSync('npm install --omit=dev', { cwd: dir, stdio: 'inherit' });
      console.log(`  done`);
    } catch (err) {
      console.error(`  Failed to install in ${dir}: ${err.message}`);
      process.exit(1);
    }
  }
}

console.log('All script dependencies installed.');
