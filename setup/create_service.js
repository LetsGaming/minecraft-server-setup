const fs = require('fs');
const path = require('path');
const loadVariables = require('./common/loadVariables');

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const MODPACK_DIR = path.join(BASE_DIR, MODPACK_NAME);

const startScript = path.join(MODPACK_DIR, 'start.sh');
const serviceFilePath = '/etc/systemd/system/prominence-rpg.service';

// Get the user executing the script
const currentUser = process.env.USER;

const serviceContent = `
[Unit]
Description=${MODPACK_NAME} Server
After=network.target

[Service]
User=${currentUser}
Group=${currentUser}
WorkingDirectory=${MODPACK_DIR}
ExecStart=/usr/bin/screen -DmS ${MODPACK_NAME} /usr/bin/bash ${startScript}
Restart=always
RestartSec=3s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
`;

fs.writeFile(serviceFilePath, serviceContent, (err) => {
  if (err) {
    console.error('Error writing the service file:', err);
    return;
  }
  console.log('Systemd service file created successfully at', serviceFilePath);
});
