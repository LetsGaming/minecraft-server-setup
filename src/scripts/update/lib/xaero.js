// scripts/update/lib/xaero.js
//
// Re-applies the Xaero config keys after a Xaero mod was installed or updated.
// Best effort: a failure is written to stderr and never reaches the caller.

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const XAERO_SLUG_PREFIX = "xaeros-";

function isXaeroSlug(slug) {
  return typeof slug === "string" && slug.startsWith(XAERO_SLUG_PREFIX);
}

/**
 * Run misc/xaero_config.sh apply for the server. `variablesPath` is the
 * common/variables.txt of the scripts directory that holds the script.
 * Resolves in every case.
 */
function applyXaeroConfig(variablesPath, serverPath) {
  const scriptsDir = path.dirname(path.dirname(variablesPath));
  const script = path.join(scriptsDir, "misc", "xaero_config.sh");
  const warn = (reason) =>
    process.stderr.write(`Could not apply the Xaero config: ${reason}\n`);

  if (!fs.existsSync(script)) {
    warn(`${script} is not installed (run migrate.sh)`);
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    try {
      execFile("bash", [script, "apply", serverPath], { timeout: 30_000 }, (err, _out, stderr) => {
        if (err) warn(`${(stderr || "").trim() || err.message}`);
        resolve();
      });
    } catch (err) {
      warn(err.message);
      resolve();
    }
  });
}

module.exports = { isXaeroSlug, applyXaeroConfig };
