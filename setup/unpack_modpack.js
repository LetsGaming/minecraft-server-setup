const fs = require('fs');
const path = require('path');
const unzipper = require('unzipper');
const loadVariables = require('./common/loadVariables');

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();
// Ensure required variables are defined
const SCRIPT_DIR = process.env.SCRIPT_DIR;

if (!SCRIPT_DIR) {
  throw new Error('Missing required environment variable: SCRIPT_DIR');
}

const UNPACK_SOURCE = path.join(SCRIPT_DIR, 'server-pack.zip');
const MODPACK_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME, MODPACK_NAME);

if (fs.existsSync(UNPACK_SOURCE)) {
  fs.createReadStream(UNPACK_SOURCE)
    .pipe(unzipper.Extract({ path: MODPACK_DIR }))
    .on('close', () => {
      console.log('Modpack unpacked successfully.');
    });
} else {
  console.error(`Modpack archive ${UNPACK_SOURCE} not found.`);
  process.exit(1);
}
