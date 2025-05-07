const path = require('path');
const loadVariables = require('../common/loadVariables');
const { exec } = require('child_process');

const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const MODPACK_DIR = path.join(BASE_DIR, INSTANCE_NAME);

const startScript = path.join(MODPACK_DIR, 'start.sh');
const serviceName = `${INSTANCE_NAME}.service`;
const serviceFilePath = `/etc/systemd/system/${serviceName}`;

// Get the user executing the script
const currentUser = process.env.USER;

const serviceContent = `
[Unit]
Description=${INSTANCE_NAME} Server
After=network.target

[Service]
User=${currentUser}
Group=${currentUser}
WorkingDirectory=${MODPACK_DIR}
ExecStart=/usr/bin/screen -DmS ${INSTANCE_NAME} /usr/bin/bash ${startScript}
Restart=always
RestartSec=3s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
`;

// Use exec to run the command with sudo privileges
exec(`echo "${serviceContent}" | sudo tee ${serviceFilePath} > /dev/null`, (err, stdout, stderr) => {
  if (err) {
    console.error('Error writing the service file:', err);
    return;
  }
  console.log('Systemd service file created successfully at', serviceFilePath);
});
