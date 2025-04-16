const fs = require('fs');
const path = require('path');
const loadVariables = require('../common/loadVariables');
const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const MODPACK_DIR = path.join(BASE_DIR, MODPACK_NAME);

function setEulaToTrue() {
    const eulaFilePath = path.join(MODPACK_DIR, 'eula.txt');

    if (!fs.existsSync(eulaFilePath)) {
        fs.writeFileSync(eulaFilePath, 'eula=false', 'utf8');
        return;
    }

    try {
        let eulaContent = fs.readFileSync(eulaFilePath, 'utf8');
        eulaContent = eulaContent.replace(/eula=false/gi, 'eula=true');
        fs.writeFileSync(eulaFilePath, eulaContent, 'utf8');
        console.log('EULA has been set to true.');
    } catch (error) {
        console.error('An error occurred while updating eula.txt:', error);
    }
}

setEulaToTrue();