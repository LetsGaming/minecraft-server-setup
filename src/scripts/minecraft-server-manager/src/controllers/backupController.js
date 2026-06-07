const path = require("path");
const fs = require("fs");
const { runScript } = require("../utils/runScript");
const config = require("../config");

const BACKUP_DIR = config.BACKUPS_PATH || path.join(config.SERVER_PATH, "..", "backups", config.INSTANCE_NAME);

// ── Helpers ──

function getBackups(dir) {
  const backups = [];
  if (!fs.existsSync(dir)) return backups;

  for (const file of fs.readdirSync(dir)) {
    const filePath = path.join(dir, file);
    const stat = fs.statSync(filePath);
    if (stat.isDirectory()) {
      backups.push(...getBackups(filePath));
    } else if (file.endsWith(".tar.gz") || file.endsWith(".tar.zst")) {
      backups.push({
        name: file,
        path: path.relative(BACKUP_DIR, filePath), // Relative path only — no absolute leak
        size: stat.size,
        modified: stat.mtime.toISOString(),
      });
    }
  }

  return backups.sort((a, b) => new Date(b.modified) - new Date(a.modified));
}

/**
 * Validate that a path stays within the backup directory.
 * Prevents path traversal attacks (e.g. ../../etc/passwd).
 */
function resolveBackupPath(relativePath) {
  const resolved = path.resolve(BACKUP_DIR, relativePath);
  if (!resolved.startsWith(path.resolve(BACKUP_DIR))) {
    return null; // Path traversal attempt
  }
  return resolved;
}

// ── Handlers ──

module.exports = {
  createBackup: async (req, res) => {
    try {
      const { archive } = req.body;
      const args = archive ? ["--archive"] : [];
      const result = await runScript(config.SCRIPTS.backup, args, 600000);
      res.json(result || { message: "Backup created." });
    } catch (err) {
      res.status(500).json(err);
    }
  },

  restoreBackup: async (req, res) => {
    const { file } = req.body;
    if (!file) return res.status(400).json({ error: "No backup file specified." });

    const filePath = resolveBackupPath(file);
    if (!filePath) return res.status(403).json({ error: "Invalid backup path." });
    if (!fs.existsSync(filePath)) return res.status(404).json({ error: "Backup file not found." });

    try {
      const result = await runScript(config.SCRIPTS.restore, ["--file", filePath, "--y"], 600000);
      res.json(result || { message: "Backup restored." });
    } catch (err) {
      res.status(500).json(err);
    }
  },

  downloadBackup: (req, res) => {
    const { file } = req.query;
    if (!file) return res.status(400).json({ error: "No backup file specified." });

    const filePath = resolveBackupPath(file);
    if (!filePath) return res.status(403).json({ error: "Invalid backup path." });
    if (!fs.existsSync(filePath)) return res.status(404).json({ error: "Backup file not found." });

    try {
      const stat = fs.statSync(filePath);
      res.setHeader("Content-Length", stat.size);
      res.download(filePath, path.basename(filePath), (err) => {
        if (err && !res.headersSent) {
          res.status(500).json({ error: "Error downloading backup." });
        }
      });
    } catch (err) {
      res.status(500).json({ error: "Failed to read file metadata." });
    }
  },

  listBackups: (req, res) => {
    res.json(getBackups(BACKUP_DIR));
  },
};
