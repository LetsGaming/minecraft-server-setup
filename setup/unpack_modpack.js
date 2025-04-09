const fs = require('fs');
const path = require('path');
const unzipper = require('unzipper');

// Ensure required variables are defined
const SCRIPT_DIR = process.env.SCRIPT_DIR;

if (!SCRIPT_DIR) {
  throw new Error('Missing required environment variable: SCRIPT_DIR');
}

const UNPACK_SOURCE = path.join(SCRIPT_DIR, 'server-pack.zip');
const MODPACK_DIR = path.join(process.env.HOME, process.env.TARGET_DIR_NAME, process.env.MODPACK_NAME);

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
