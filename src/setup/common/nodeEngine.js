"use strict";

// Tells whether the Node that will run a package meets the package's own
// "engines.node" range. The API wrapper declares ">=22" while Debian 13 ships
// Node 20; npm only prints a warning and the wrapper may still run, so setup
// and doctor report the mismatch instead of blocking on it.

const fs = require("fs");
const semver = require("semver");

/**
 * @param {string} packageJsonPath
 * @param {string} [nodeVersion] defaults to the running Node
 * @returns {string|null} a one-line warning, or null when the range is met,
 *   absent or unreadable
 */
function engineWarning(packageJsonPath, nodeVersion = process.version) {
  let range;
  try {
    range = JSON.parse(fs.readFileSync(packageJsonPath, "utf8")).engines?.node;
  } catch {
    return null;
  }
  if (typeof range !== "string" || !semver.validRange(range)) return null;
  if (semver.satisfies(nodeVersion, range, { includePrerelease: true })) return null;
  return `Node ${nodeVersion.replace(/^v/, "")} is older than the ${range} that ${packageJsonPath} asks for; ` +
    "the service may misbehave. Install a newer Node.js (see the README) if it does.";
}

module.exports = { engineWarning };
