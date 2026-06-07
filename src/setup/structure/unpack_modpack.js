const fs = require("fs");
const path = require("path");
const unzipper = require("unzipper");
const loadVariables = require("../common/loadVariables");

const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();
// Ensure required variables are defined
const SCRIPT_DIR = process.env.SCRIPT_DIR;

if (!SCRIPT_DIR) {
  throw new Error("Missing required environment variable: SCRIPT_DIR");
}

const TEMP_DIR = path.join(SCRIPT_DIR, "setup", "download", "temp");

const modpack_source = path.join(TEMP_DIR, "server-pack.zip");
const mods_source = path.join(TEMP_DIR, "mods");

const MODPACK_DIR = path.join(
  process.env.MAIN_DIR,
  TARGET_DIR_NAME,
  INSTANCE_NAME
);
const MODS_DIR = path.join(MODPACK_DIR, "mods");

unpackModpack();

function unpackModpack() {
  if (fs.existsSync(modpack_source)) {
    fs.createReadStream(modpack_source)
      .pipe(unzipper.Extract({ path: MODPACK_DIR }))
      .on("close", () => {
        console.log("Modpack unpacked successfully.");
        moveMods();
      });
  } else {
    console.error(`Modpack archive ${modpack_source} not found.`);
    process.exit(1);
  }
}

function moveMods() {
  if (fs.existsSync(mods_source)) {
    fs.readdir(mods_source, (err, files) => {
      if (err) {
        console.error("Error reading mods directory:", err);
        return;
      }

      if (!fs.existsSync(MODS_DIR)) {
        fs.mkdirSync(MODS_DIR, { recursive: true });
      }

      files.forEach((file) => {
        const sourcePath = path.join(mods_source, file);
        const destPath = path.join(MODS_DIR, file);

        fs.rename(sourcePath, destPath, (err) => {
          if (err) {
            console.error(`Error moving ${file}:`, err);
          } else {
            console.log(`Moved ${file} to ${MODS_DIR}`);
          }
        });
      });
    });
  } else {
    console.error(`Mods directory ${mods_source} not found.`);
  }
}
