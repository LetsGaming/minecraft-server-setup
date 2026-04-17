'use strict';

/**
 * minecraft-bot API wrapper
 *
 * Runs as a systemd service on the MC server VM. Exposes the local MC
 * instance over HTTP so the Discord bot (on any machine) can:
 *   - Read whitelist.json, stats files, server.properties, mods, backups
 *   - Tail latest.log
 *   - Stream new log lines in real time (SSE)
 *   - Run management scripts (start / stop / restart / backup / status)
 *   - Send RCON / screen commands
 *
 * Config is read from variables.txt in the common/ directory — the same
 * file the shell scripts use. No separate config needed.
 *
 * Start: node index.js
 * The systemd service is created automatically during setup when
 * API_SERVER.ENABLED = true in variables.json.
 */

const express = require('express');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { execFile, spawn } = require('child_process');
const readline = require('readline');

// ── Load variables.txt ────────────────────────────────────────────────────

const SCRIPT_DIR = __dirname;
const VARS_FILE = path.join(SCRIPT_DIR, '..', 'common', 'variables.txt');

function loadVars() {
  if (!fs.existsSync(VARS_FILE)) {
    console.error(`[api-server] variables.txt not found at ${VARS_FILE}`);
    process.exit(1);
  }
  const vars = {};
  for (const line of fs.readFileSync(VARS_FILE, 'utf-8').split(/\r?\n/)) {
    const m = line.match(/^(\w+)="?([^"]*)"?$/);
    if (m) vars[m[1]] = m[2];
  }
  return vars;
}

const vars = loadVars();
const PORT = parseInt(vars['API_SERVER_PORT'] || '3000', 10);
const API_KEY = vars['API_SERVER_KEY'] || '';
const SERVER_PATH = vars['SERVER_PATH'] || '';
const INSTANCE_NAME = vars['INSTANCE_NAME'] || 'server';
const LINUX_USER = vars['USER'] || 'minecraft';
const USE_RCON = vars['USE_RCON'] === 'true';
const RCON_HOST = vars['RCON_HOST'] || 'localhost';
const RCON_PORT = parseInt(vars['RCON_PORT'] || '25575', 10);
const RCON_PASSWORD = vars['RCON_PASSWORD'] || '';
const BACKUPS_PATH = vars['BACKUPS_PATH'] || '';

// Script dir is two levels up from api-server/ (scripts/<instance>/)
const INSTANCE_SCRIPTS_DIR = path.resolve(SCRIPT_DIR, '..');

const SCRIPT_MAP = {
  start: 'start.sh',
  stop: 'shutdown.sh',
  restart: 'smart_restart.sh',
  backup: 'backup/backup.sh',
  status: 'misc/status.sh',
};

const SCRIPT_TIMEOUTS = {
  start: 30000,
  stop: 60000,
  restart: 60000,
  backup: 300000,
  status: 15000,
};

// ── Minimal RCON client ───────────────────────────────────────────────────

function encodePkt(id, type, body) {
  const b = Buffer.from(body, 'utf-8');
  const len = 4 + 4 + b.length + 2;
  const buf = Buffer.alloc(4 + len);
  buf.writeInt32LE(len, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  b.copy(buf, 12);
  buf[12 + b.length] = 0;
  buf[13 + b.length] = 0;
  return buf;
}

function decodePkt(buf) {
  if (buf.length < 14) return null;
  const length = buf.readInt32LE(0);
  if (buf.length < 4 + length) return null;
  return {
    id: buf.readInt32LE(4),
    type: buf.readInt32LE(8),
    body: buf.toString('utf-8', 12, 4 + length - 2),
    totalSize: 4 + length,
  };
}

class RconClient {
  constructor(host, port, password) {
    this.host = host;
    this.port = port;
    this.password = password;
    this._socket = null;
    this._auth = false;
    this._connecting = false;
    this._cmdId = 10;
    this._pending = new Map();
    this._buf = Buffer.alloc(0);
    this._authResolve = null;
    this._authReject = null;
    this.lastSuccessTime = 0;
  }

  _cleanup() {
    this._auth = false;
    this._connecting = false;
    if (this._socket) { this._socket.removeAllListeners(); this._socket.destroy(); this._socket = null; }
    for (const [, cb] of this._pending) { clearTimeout(cb.timer); cb.reject(new Error('RCON lost')); }
    this._pending.clear();
    this._buf = Buffer.alloc(0);
    if (this._authReject) { this._authReject(new Error('RCON lost')); this._authResolve = null; this._authReject = null; }
  }

  connect() {
    return new Promise((resolve, reject) => {
      if (this._auth && this._socket && !this._socket.destroyed) return resolve();
      if (this._connecting) {
        const poll = setInterval(() => {
          if (this._auth) { clearInterval(poll); resolve(); }
          else if (!this._connecting) { clearInterval(poll); reject(new Error('RCON failed')); }
        }, 50);
        return;
      }
      this._cleanup();
      this._connecting = true;
      this._authResolve = resolve;
      this._authReject = reject;
      this._socket = new net.Socket();
      this._socket.setKeepAlive(true, 30000);
      const authTimeout = setTimeout(() => { this._cleanup(); reject(new Error('RCON auth timeout')); }, 10000);
      this._socket.connect(this.port, this.host, () => {
        this._socket.write(encodePkt(1, 3, this.password));
      });
      this._socket.on('data', (data) => {
        this._buf = Buffer.concat([this._buf, data]);
        for (;;) {
          const pkt = decodePkt(this._buf);
          if (!pkt) break;
          this._buf = this._buf.subarray(pkt.totalSize);
          if (!this._auth) {
            clearTimeout(authTimeout);
            if (pkt.id === -1) { this._connecting = false; this._cleanup(); reject(new Error('RCON auth failed')); return; }
            if (pkt.id === 1) { this._auth = true; this._connecting = false; this._authResolve(); this._authResolve = null; this._authReject = null; }
            continue;
          }
          const cb = this._pending.get(pkt.id);
          if (cb) { clearTimeout(cb.timer); this._pending.delete(pkt.id); this.lastSuccessTime = Date.now(); cb.resolve(pkt.body); }
        }
      });
      this._socket.on('error', () => this._cleanup());
      this._socket.on('close', () => this._cleanup());
    });
  }

  async send(command, timeoutMs = 5000) {
    await this.connect();
    const id = this._cmdId++;
    if (this._cmdId > 2e9) this._cmdId = 10;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this._pending.delete(id); reject(new Error('RCON timeout')); }, timeoutMs);
      this._pending.set(id, { resolve, reject, timer });
      this._socket.write(encodePkt(id, 2, command));
    });
  }
}

const rcon = USE_RCON && RCON_PASSWORD ? new RconClient(RCON_HOST, RCON_PORT, RCON_PASSWORD) : null;

// ── Local operations ──────────────────────────────────────────────────────

async function sendCommand(command) {
  if (rcon) {
    try {
      const cmd = command.startsWith('/') ? command.slice(1) : command;
      return await rcon.send(cmd);
    } catch {
      // fall through to screen
    }
  }
  const formatted = command.startsWith('/') ? command : `/${command}`;
  await new Promise((resolve) => {
    execFile('sudo', ['-n', '-u', LINUX_USER, 'screen', '-S', INSTANCE_NAME, '-X', 'stuff', `${formatted}\r`],
      { timeout: 15000 }, (err) => {
        if (err) console.warn(`[api-server] screen send failed: ${err.message}`);
        resolve();
      });
  });
  return null;
}

async function isRunning() {
  if (rcon) {
    if (Date.now() - rcon.lastSuccessTime < 15000) return true;
    for (let i = 0; i < 2; i++) {
      if (i > 0) await new Promise(r => setTimeout(r, 500));
      try { await rcon.send('list', 3000); return true; } catch { /* next */ }
    }
    return false;
  }
  return new Promise((resolve) => {
    execFile('sudo', ['-n', '-u', LINUX_USER, 'screen', '-list'], { timeout: 10000 }, (err, stdout) => {
      resolve(!err && new RegExp(`\\b\\d+\\.${INSTANCE_NAME}\\b`).test(stdout));
    });
  });
}

async function getList() {
  if (rcon) {
    try {
      const r = await rcon.send('list');
      const cm = r.match(/There are\s+(\d+)\s*(?:of a max of\s*(\d+)|\/\s*(\d+))\s*players online/i);
      const pm = r.match(/players online:\s*(.*)$/i);
      return {
        playerCount: cm?.[1] ?? '0',
        maxPlayers: cm?.[2] ?? cm?.[3] ?? '?',
        players: pm?.[1] ? pm[1].split(',').map(s => s.trim()).filter(Boolean) : [],
      };
    } catch { /* fall through */ }
  }
  return { playerCount: '0', maxPlayers: '?', players: [] };
}

async function getTps() {
  if (!rcon) return null;
  try {
    const r = await rcon.send('tps');
    if (!r.toLowerCase().includes('unknown')) {
      const m = r.match(/([\d.]+)(?:,\s*([\d.]+)(?:,\s*([\d.]+))?)?/);
      if (m) return { type: 'paper', tps1m: parseFloat(m[1]), tps5m: parseFloat(m[2] ?? m[1]), tps15m: parseFloat(m[3] ?? m[1]), raw: r };
    }
  } catch { /* try vanilla */ }
  try {
    const r = await rcon.send('tick query');
    if (r.toLowerCase().includes('unknown')) return null;
    const msptMatch = r.match(/Average time per tick:\s*([\d.]+)\s*ms/i);
    if (!msptMatch) return { type: 'minimal', tps1m: 0, raw: r };
    const mspt = parseFloat(msptMatch[1]);
    const result = { type: 'vanilla', tps1m: Math.min(20, 1000 / mspt), mspt, raw: r };
    const p50 = r.match(/P50:\s*([\d.]+)\s*ms/i);
    const p95 = r.match(/P95:\s*([\d.]+)\s*ms/i);
    const p99 = r.match(/P99:\s*([\d.]+)\s*ms/i);
    if (p50?.[1]) result.p50 = parseFloat(p50[1]);
    if (p95?.[1]) result.p95 = parseFloat(p95[1]);
    if (p99?.[1]) result.p99 = parseFloat(p99[1]);
    return result;
  } catch { return null; }
}

async function getLevelName() {
  const propsPath = path.join(SERVER_PATH, 'server.properties');
  try {
    const text = fs.readFileSync(propsPath, 'utf-8');
    const m = text.match(/^level-name\s*=\s*(.+)$/m);
    return m?.[1]?.trim() ?? 'world';
  } catch { return 'world'; }
}

async function tailLog(lines) {
  const logFile = path.join(SERVER_PATH, 'logs', 'latest.log');
  return new Promise((resolve) => {
    execFile('tail', ['-n', String(lines), logFile], { timeout: 5000 }, (err, stdout) => {
      resolve(err ? '' : stdout);
    });
  });
}

function getWhitelist() {
  try {
    return JSON.parse(fs.readFileSync(path.join(SERVER_PATH, 'whitelist.json'), 'utf-8'));
  } catch { return []; }
}

async function getStats(uuid) {
  const levelName = await getLevelName();
  const p = path.join(SERVER_PATH, levelName, 'stats', `${uuid}.json`);
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')); } catch { return null; }
}

async function listStatsUuids() {
  const levelName = await getLevelName();
  const dir = path.join(SERVER_PATH, levelName, 'stats');
  try {
    return fs.readdirSync(dir).filter(f => f.endsWith('.json')).map(f => f.slice(0, -5));
  } catch { return []; }
}

function getModSlugs() {
  // scriptDir for this instance is one level up from api-server/
  const jsonPath = path.join(INSTANCE_SCRIPTS_DIR, 'common', 'downloaded_versions.json');
  if (!fs.existsSync(jsonPath)) throw new Error(`downloaded_versions.json not found at ${jsonPath}`);
  const stat = fs.statSync(jsonPath);
  const raw = JSON.parse(fs.readFileSync(jsonPath, 'utf-8'));
  return { slugs: Object.keys(raw.mods ?? {}), mtimeMs: stat.mtimeMs };
}

function getBackups() {
  const backupsBase = BACKUPS_PATH;
  const subdirs = ['hourly', 'archives/daily', 'archives/weekly', 'archives/monthly', 'archives/update'];
  const dirs = [];
  let totalBytes = 0;
  for (const dir of subdirs) {
    const fullDir = path.join(backupsBase, dir);
    if (!fs.existsSync(fullDir)) continue;
    const files = fs.readdirSync(fullDir).filter(f => f.endsWith('.tar.zst') || f.endsWith('.tar.gz'));
    if (!files.length) continue;
    files.sort().reverse();
    const latest = files[0];
    const stat = fs.statSync(path.join(fullDir, latest));
    totalBytes += stat.size;
    dirs.push({ dir, count: files.length, latestFile: latest, latestMtimeMs: stat.mtimeMs, latestSizeBytes: stat.size });
  }
  return { dirs, totalBytes };
}

function runScript(action, args) {
  const scriptRelPath = SCRIPT_MAP[action];
  if (!scriptRelPath) throw new Error(`Unknown script action: ${action}`);
  const scriptPath = path.join(INSTANCE_SCRIPTS_DIR, scriptRelPath);
  if (!fs.existsSync(scriptPath)) throw new Error(`Script not found: ${scriptPath}`);
  const timeoutMs = SCRIPT_TIMEOUTS[action] ?? 120000;

  return new Promise((resolve, reject) => {
    const child = spawn('sudo', ['-n', '-u', LINUX_USER, 'bash', scriptPath, ...(args || [])], {
      cwd: INSTANCE_SCRIPTS_DIR,
      env: { ...process.env, HOME: `/home/${LINUX_USER}` },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '', stderr = '', killed = false;
    const timer = setTimeout(() => {
      killed = true;
      child.kill('SIGTERM');
      reject(new Error(`Script timed out after ${timeoutMs / 1000}s\n\nOutput:\n${stdout.slice(-500)}`));
    }, timeoutMs);
    child.stdout.on('data', d => { stdout += d.toString(); });
    child.stderr.on('data', d => { stderr += d.toString(); });
    child.on('close', code => {
      if (killed) return;
      clearTimeout(timer);
      if (/\[SUDO ERROR\]/i.test(stdout + '\n' + stderr)) {
        reject(new Error(`Sudo not configured for '${LINUX_USER}'. See docs/sudoers-setup.md.`));
        return;
      }
      stderr = stderr.split('\n').filter(l => !l.includes('[sudo]') && !l.includes('password for')).join('\n').trim();
      resolve({ output: stdout.trim(), stderr, exitCode: code });
    });
    child.on('error', err => { clearTimeout(timer); reject(new Error(`Failed to start script: ${err.message}`)); });
  });
}

// ── SSE log streaming ─────────────────────────────────────────────────────

const sseClients = new Set();
const LOG_FILE = path.join(SERVER_PATH, 'logs', 'latest.log');
let logLastSize = 0;
let logReading = false;

async function processLogChanges(event) {
  if (logReading) return;
  logReading = true;
  try {
    if (event === 'rename') {
      try { fs.accessSync(LOG_FILE); logLastSize = 0; } catch { return; }
    }
    let stat;
    try { stat = fs.statSync(LOG_FILE); } catch { return; }
    if (stat.size < logLastSize) logLastSize = 0;
    if (stat.size === logLastSize) return;

    const stream = fs.createReadStream(LOG_FILE, { start: logLastSize, end: stat.size - 1 });
    const rl = readline.createInterface({ input: stream });
    for await (const line of rl) {
      const payload = `data: ${JSON.stringify({ line, serverId: INSTANCE_NAME })}\n\n`;
      for (const res of [...sseClients]) {
        try { res.write(payload); } catch { sseClients.delete(res); }
      }
    }
    logLastSize = stat.size;
  } catch { /* swallow */ } finally {
    logReading = false;
  }
}

// Seed offset so we don't replay the whole log on first connect
try { logLastSize = fs.statSync(LOG_FILE).size; } catch { logLastSize = 0; }

// Watch with fs.watch + polling fallback
try {
  const logsDir = path.dirname(LOG_FILE);
  const watcher = fs.watch(logsDir, (event, filename) => {
    if (filename === 'latest.log') processLogChanges(event).catch(() => {});
  });
  watcher.on('error', () => {});
} catch { /* polling only */ }

setInterval(() => processLogChanges('change').catch(() => {}), 1000);

// ── Express app ───────────────────────────────────────────────────────────

const app = express();
app.use(express.json());

// Ensure log directory exists (used by PM2 when running via ecosystem.config.cjs)
const LOG_DIR = path.join(SCRIPT_DIR, 'logs');
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

// Auth
app.use((req, res, next) => {
  if (!API_KEY) return next();
  const key = req.headers['x-api-key'] || '';
  if (key !== API_KEY) { res.status(401).json({ error: 'Unauthorized' }); return; }
  next();
});

// Health
app.get('/health', (_req, res) => {
  res.json({ ok: true, instance: INSTANCE_NAME });
});

// ── Routes (mirror serverAccess.ts exactly) ───────────────────────────────

app.get('/instances/:id/logs/tail', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  const lines = Math.min(Number(req.query.lines ?? 10), 500);
  try { res.json({ output: await tailLog(lines) }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/logs/stream', (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();
  const hb = setInterval(() => { try { res.write(':heartbeat\n\n'); } catch { clearInterval(hb); } }, 20000);
  sseClients.add(res);
  req.on('close', () => { clearInterval(hb); sseClients.delete(res); });
});

app.get('/instances/:id/whitelist', (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json({ whitelist: getWhitelist() }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/level-name', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json({ levelName: await getLevelName() }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/stats', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json({ uuids: await listStatsUuids() }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/stats/:uuid', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json({ stats: await getStats(req.params.uuid) }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/mods', (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json(getModSlugs()); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/backups', (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json(getBackups()); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.post('/instances/:id/scripts/run', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  const { action, args } = req.body;
  if (!action) { res.status(400).json({ error: 'Missing action' }); return; }
  try { res.json(await runScript(action, args)); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/running', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json({ running: await isRunning() }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/list', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json(await getList()); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.get('/instances/:id/tps', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  try { res.json({ tps: await getTps() }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.post('/instances/:id/command', async (req, res) => {
  if (req.params.id !== INSTANCE_NAME) { res.status(404).json({ error: 'Instance not found' }); return; }
  const { command } = req.body;
  if (!command) { res.status(400).json({ error: 'Missing command' }); return; }
  try { res.json({ result: await sendCommand(command) }); }
  catch (err) { res.status(500).json({ error: String(err) }); }
});

app.listen(PORT, () => {
  console.log(`[api-server] ${INSTANCE_NAME} — listening on :${PORT}`);
});
