const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');
const loadVariables = require('../common/loadVariables');

const { TARGET_DIR_NAME, INSTANCE_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const MODPACK_DIR = path.join(BASE_DIR, INSTANCE_NAME);

const startScript = path.join(MODPACK_DIR, 'start.sh');
const serviceName = `${INSTANCE_NAME}.service`;
const serviceFilePath = `/etc/systemd/system/${serviceName}`;

const currentUser = process.env.USER;

const serviceContent = `[Unit]
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

try {
  // Write to a temp file first, then use sudo mv to place it safely
  // This avoids shell injection through exec() with interpolated strings
  const tmpFile = path.join('/tmp', `mc-service-${Date.now()}.tmp`);
  fs.writeFileSync(tmpFile, serviceContent, 'utf-8');
  execSync(`sudo mv "${tmpFile}" "${serviceFilePath}"`);
  execSync(`sudo chmod 644 "${serviceFilePath}"`);
  console.log(`Systemd service file created successfully at ${serviceFilePath}`);
} catch (err) {
  console.error('Error creating the service file:', err.message);
  process.exit(1);
}
