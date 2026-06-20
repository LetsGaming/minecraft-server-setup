const path = require("path");
const fs = require("fs");

// Load variables (falls back to the .example.json when the git-ignored live
// file is absent, so a fresh clone still runs)
const { loadVariablesJson } = require("../download/json/load");
const { api_key } = loadVariablesJson("curseforge_variables");
// Construct path
const variablesFilePath = path.resolve(
  __dirname,
  "..",
  "..",
  "scripts",
  "common",
  "curseforge.txt",
);

// Prepare content. curseforge.txt is sourced by bash, so the value must be
// safely single-quoted: inside single quotes the shell treats everything
// literally except a single quote, which we escape as '\'' .
function shSquote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}
const variablesContent = [`API_KEY=${shSquote(api_key)}`].join("\n");

// Write to file (0600 — contains the CurseForge API key)
fs.writeFileSync(variablesFilePath, variablesContent, { mode: 0o600 });
fs.chmodSync(variablesFilePath, 0o600);

console.log(`Curseforge Variables written to ${variablesFilePath}`);
