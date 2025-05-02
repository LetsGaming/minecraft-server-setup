const { exec } = require("child_process");
const { promisify } = require("util");

const loadVariables = require("../../common/loadVariables");
const { MODPACK_NAME } = loadVariables();

const SERVICE_NAME = `${MODPACK_NAME}-manager.service`;
const execAsync = promisify(exec);

async function enableAndStartService() {
  try {
    console.log(`Enabling ${SERVICE_NAME}...`);
    await execAsync(`sudo systemctl enable "${SERVICE_NAME}"`);

    console.log(`Starting ${SERVICE_NAME}...`);
    await execAsync(`sudo systemctl start "${SERVICE_NAME}"`);

    console.log(`${SERVICE_NAME} enabled and started successfully.`);
  } catch (err) {
    console.error(`Failed to enable/start ${SERVICE_NAME}:`, err);
    process.exit(1);
  }
}

enableAndStartService();
