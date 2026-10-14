// scripts/update/lib/variables.js
//
// Reader for common/variables.txt (KEY="value" lines). The file is only ever
// parsed here, never sourced, so a value cannot execute anything.

const fs = require("fs");

/** Parse variables.txt text into a plain object. Later keys win. */
function parseVariables(content) {
  const vars = {};
  for (const line of content.split(/\r?\n/)) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      // Setup escapes \ " $ and ` inside double quotes (shDquote in
      // set_common_variables.js); undo exactly that, as bash would (S-030).
      value = value.slice(1, -1).replace(/\\(["$`\\])/g, "$1");
    } else if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1);
    }
    vars[match[1]] = value;
  }
  return vars;
}

/**
 * Load variables.txt from `variablesPath`.
 *
 * @param {string} variablesPath
 * @param {{ optional?: boolean }} [opts]  With `optional`, a missing file
 *   yields {} instead of throwing.
 */
function loadVariables(variablesPath, { optional = false } = {}) {
  if (optional && !fs.existsSync(variablesPath)) return {};
  return parseVariables(fs.readFileSync(variablesPath, "utf8"));
}

module.exports = { parseVariables, loadVariables };
