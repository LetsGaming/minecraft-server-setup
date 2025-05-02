const path = require("path");
const loadVariables = require("../common/loadVariables");
const { exec } = require("child_process");

const { TARGET_DIR_NAME, MODPACK_NAME } = loadVariables();

const BASE_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME);
const INTERFACE_DIR = path.join(BASE_DIR, "scripts", MODPACK_NAME, "interface");

const startScript = path.join(INTERFACE_DIR, "app.js");

const serviceName = `${MODPACK_NAME}-manager.service`;
const serviceFilePath = `/etc/systemd/system/${serviceName}`;

// Get the user executing the script
const currentUser = process.env.USER;

const SCREEN_NAME = `${MODPACK_NAME}-manager`;

const serviceContent = `
[Unit]
Description=${MODPACK_NAME} Server Manager
After=network.target

[Service]
User=${currentUser}
Group=${currentUser}
WorkingDirectory=${INTERFACE_DIR}
ExecStart=/usr/bin/screen -DmS ${SCREEN_NAME} /usr/bin/node ${startScript}
Restart=always
RestartSec=3s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
`;

// Use exec to run the command with sudo privileges
exec(
  `echo "${serviceContent}" | sudo tee ${serviceFilePath} > /dev/null`,
  (err, stdout, stderr) => {
    if (err) {
      console.error("Error writing the service file:", err);
      return;
    }
    console.log(
      "Systemd service file created successfully at",
      serviceFilePath
    );
  }
);
