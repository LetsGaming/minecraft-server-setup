"use strict";

const { spawnSync } = require("child_process");

/**
 * SEC-03: write a root-owned file whose contents come from `content`, without
 * staging a world-writable file in /tmp and without passing the contents
 * through a shell.
 *
 * The contents are streamed to `sudo tee <destPath>` on stdin, so:
 *   • no interpolated string is ever handed to a shell (no injection), and
 *   • there is no predictable, attacker-writable temp file to race/symlink.
 *
 * This also means the application user no longer needs a broad
 * `mv /tmp/...service /etc/systemd/system/` sudoers grant — see
 * docs/sudoers-setup.md.
 *
 * @param {string} destPath  Absolute destination path (fixed, not user input).
 * @param {string} content   File contents.
 * @param {string} [mode]    chmod mode, default "644".
 */
function writeRootFile(destPath, content, mode = "644") {
  const tee = spawnSync("sudo", ["tee", destPath], {
    input: content,
    stdio: ["pipe", "ignore", "inherit"],
  });
  if (tee.error) {
    throw new Error(`Failed to invoke sudo tee for ${destPath}: ${tee.error.message}`);
  }
  if (tee.status !== 0) {
    throw new Error(`sudo tee exited with status ${tee.status} writing ${destPath}`);
  }

  const chmod = spawnSync("sudo", ["chmod", mode, destPath], { stdio: "inherit" });
  if (chmod.status !== 0) {
    throw new Error(`sudo chmod ${mode} failed for ${destPath}`);
  }
}

module.exports = { writeRootFile };
