/**
 * PM2 Ecosystem Configuration — minecraft-bot API server
 *
 * This file lives in scripts/<instance>/api-server/ alongside index.js.
 * The instance name and port are read at runtime from ../common/variables.txt,
 * so this config works for any instance without modification.
 *
 * Usage (from the api-server/ directory):
 *   pm2 start ecosystem.config.cjs
 *   pm2 start ecosystem.config.cjs --env production
 *
 * Or from anywhere:
 *   pm2 start /path/to/scripts/<instance>/api-server/ecosystem.config.cjs
 *
 * Common commands:
 *   pm2 list
 *   pm2 logs <instance-name>-api
 *   pm2 restart <instance-name>-api
 *   pm2 stop <instance-name>-api
 *   pm2 monit
 *
 * To start on boot:
 *   pm2 startup        (run the printed command as root)
 *   pm2 save
 */

const path = require('path');
const fs = require('fs');

// ── Resolve instance name from variables.txt ──────────────────────────────
// This lets PM2 show a meaningful process name in `pm2 list` without
// hardcoding anything in this file.

const VARS_FILE = path.resolve(__dirname, '..', 'common', 'variables.txt');

let instanceName = 'mc-api';
if (fs.existsSync(VARS_FILE)) {
  for (const line of fs.readFileSync(VARS_FILE, 'utf-8').split(/\r?\n/)) {
    const m = line.match(/^INSTANCE_NAME="?([^"]+)"?$/);
    if (m) { instanceName = m[1]; break; }
  }
}

// ─────────────────────────────────────────────────────────────────────────

module.exports = {
  apps: [
    {
      name: `${instanceName}-api`,
      script: 'index.js',
      cwd: __dirname,

      // ── Node ──
      interpreter: 'node',
      instances: 1,
      exec_mode: 'fork',

      // ── Process management ──
      autorestart: true,
      max_restarts: 10,
      min_uptime: '10s',
      restart_delay: 5000,

      // ── Logging ──
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      out_file: './logs/pm2-out.log',
      error_file: './logs/pm2-error.log',
      merge_logs: true,

      // ── Resource limits ──
      // The api-server is lightweight; 256 MB is a generous ceiling.
      max_memory_restart: '256M',

      // ── Environment ──
      env: {
        NODE_ENV: 'development',
      },
      env_production: {
        NODE_ENV: 'production',
      },
    },
  ],
};
