'use strict';

/**
 * Creates a systemd service that runs the minecraft-bot API wrapper
 * for this MC instance. The service starts on boot, runs as the MC
 * user, and restarts automatically if it crashes.
 *
 * Called during setup when API_SERVER.ENABLED = true in variables.json.
 */

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');
const loadVariables = require('../common/loadVariables');

const vars = loadVariables();
const { TARGET_DIR_NAME, INSTANCE_NAME } = vars;
const apiServer = vars.API_SERVER || {};

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const SCRIPTS_DIR = path.join(BASE_DIR, 'scripts', INSTANCE_NAME);
const API_SERVER_DIR = path.join(SCRIPTS_DIR, 'api-server');
const apiServerEntry = path.join(API_SERVER_DIR, 'index.js');

const currentUser = process.env.USER;
const serviceName = `${INSTANCE_NAME}-api-server.service`;
const serviceFilePath = `/etc/systemd/system/${serviceName}`;

// Install express if not already present
if (!fs.existsSync(path.join(API_SERVER_DIR, 'node_modules', 'express'))) {
  console.log('[api-server] Installing dependencies...');
  try {
    execSync('npm install --omit=dev', { cwd: API_SERVER_DIR, stdio: 'inherit' });
  } catch (err) {
    console.error(`[api-server] npm install failed: ${err.message}`);
    process.exit(1);
  }
}

const serviceContent = `[Unit]
Description=minecraft-bot API wrapper — ${INSTANCE_NAME}
After=network.target

[Service]
Type=simple
User=${currentUser}
Group=${currentUser}
WorkingDirectory=${API_SERVER_DIR}
ExecStart=/usr/bin/node ${apiServerEntry}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${INSTANCE_NAME}-api-server

[Install]
WantedBy=multi-user.target
`;

try {
  const tmpFile = path.join('/tmp', `mc-api-service-${Date.now()}.tmp`);
  fs.writeFileSync(tmpFile, serviceContent, 'utf-8');
  execSync(`sudo mv "${tmpFile}" "${serviceFilePath}"`);
  execSync(`sudo chmod 644 "${serviceFilePath}"`);
  execSync('sudo systemctl daemon-reload');
  execSync(`sudo systemctl enable ${serviceName}`);
  execSync(`sudo systemctl start ${serviceName}`);
  console.log(`[api-server] Service created and started: ${serviceName}`);
  console.log(`[api-server] Listening on port ${apiServer.PORT || 3000}`);
} catch (err) {
  console.error(`[api-server] Failed to create service: ${err.message}`);
  process.exit(1);
}
