const path = require("path");
const fs = require("fs");

// Load variables
const curseforge_variables = require("../download/curseforge_variables.json");
const { api_key } = curseforge_variables;
// Construct path
const variablesFilePath = path.resolve(
  __dirname,
  "..",
  "..",
  "scripts",
  "common",
  "curseforge.txt"
);

// Prepare content
const variablesContent = [
  `API_KEY='${api_key}'`,
].join("\n");

// Write to file
fs.writeFileSync(variablesFilePath, variablesContent);

console.log(`Curseforge Variables written to ${variablesFilePath}`);
