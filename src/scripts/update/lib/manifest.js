// scripts/update/lib/manifest.js
//
// The one reader and writer of downloaded_versions.json for the update
// scripts (S-024).
//  - A manifest that exists but does not parse is an error, never {}: the next
//    save would have written back only gameVersion and dropped every mod.
//  - Writes go to a temp file named for this process, are synced, then renamed
//    over the manifest, so two scripts never share a temp file and a reader
//    never sees half a manifest.

const crypto = require("crypto");
const fs = require("fs");

class ManifestError extends Error {
  constructor(message) {
    super(message);
    this.name = "ManifestError";
  }
}

/**
 * @param {string} file
 * @param {{ missingOk?: boolean }} [opts] With missingOk a missing file reads as {}.
 */
function readManifest(file, { missingOk = false } = {}) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (err) {
    if (err.code === "ENOENT" && missingOk) return {};
    if (err.code === "ENOENT") throw new ManifestError(`downloaded_versions.json not found at: ${file}`);
    throw err;
  }
  try {
    const data = JSON.parse(text);
    if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("not an object");
    return data;
  } catch (err) {
    throw new ManifestError(`Could not parse downloaded_versions.json (${err.message}); fix or restore it before changing mods.`);
  }
}

function writeManifest(file, data) {
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  const fd = fs.openSync(tmp, "wx", 0o644);
  try {
    fs.writeFileSync(fd, JSON.stringify(data, null, 2), "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.renameSync(tmp, file);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

module.exports = { readManifest, writeManifest, ManifestError };
