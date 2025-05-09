const path = require("path");
const fs = require("fs");

const loadVariables = require("../../setup/common/loadVariables.js");
const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();

const tmpDir = path.join(process.env.SCRIPT_DIR, "vanilla", "temp");
const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const INSTANCE_DIR = path.join(BASE_DIR, INSTANCE_NAME);

function moveContentsSync(srcDir, destDir) {
  const entries = fs.readdirSync(srcDir, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(srcDir, entry.name);
    const destPath = path.join(destDir, entry.name);

    if (entry.isDirectory()) {
      if (!fs.existsSync(destPath)) {
        fs.mkdirSync(destPath, { recursive: true });
      }
      moveContentsSync(srcPath, destPath);
      fs.rmdirSync(srcPath); // remove empty source dir after moving
    } else {
      fs.renameSync(srcPath, destPath);
    }
  }
}

function copyStartScript(srcDir, destDir) {
  const startScriptPath = path.join(srcDir, "start.sh");
  const destPath = path.join(destDir, "start.sh");

  if (fs.existsSync(startScriptPath)) {
    fs.copyFileSync(startScriptPath, destPath);
    console.log(`Copied start.sh from ${startScriptPath} to ${destPath}`);
  } else {
    console.error("Start script not found in source directory.");
    process.exit(1);
  }
}

// Ensure target exists
if (!fs.existsSync(INSTANCE_DIR)) {
  fs.mkdirSync(INSTANCE_DIR, { recursive: true });
}

// Move tmp -> instance
moveContentsSync(tmpDir, INSTANCE_DIR);
copyStartScript(path.join(process.env.SCRIPT_DIR, "vanilla"), INSTANCE_DIR);
