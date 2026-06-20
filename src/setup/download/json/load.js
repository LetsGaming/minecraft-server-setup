"use strict";

const fs = require("fs");
const path = require("path");

/**
 * Load a `<baseName>.json` config from this directory, falling back to the
 * committed `<baseName>.example.json` template when the live file is absent.
 *
 * `curseforge_variables.json` is git-ignored because it holds an API key, so a
 * fresh clone won't have it. Falling back to the example (which ships with
 * "none" placeholders) lets setup run and fail with a clear "set your API key"
 * message instead of a missing-module crash at require() time.
 *
 * @param {string} baseName e.g. "curseforge_variables"
 * @returns {object}
 */
function loadVariablesJson(baseName) {
  const live = path.join(__dirname, `${baseName}.json`);
  const example = path.join(__dirname, `${baseName}.example.json`);
  const file = fs.existsSync(live) ? live : example;
  return JSON.parse(fs.readFileSync(file, "utf-8"));
}

module.exports = { loadVariablesJson };
