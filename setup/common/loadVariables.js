// common/loadVariables.js
const path = require("path");
const fs = require("fs");

function loadVariables() {
  const variablesPath = path.resolve(__dirname, "../variables.json");
  if (!fs.existsSync(variablesPath)) {
    throw new Error(
      `Missing variables.json at expected path: ${variablesPath}`
    );
  }

  const data = JSON.parse(fs.readFileSync(variablesPath, "utf-8"));

  const requiredVars = ["TARGET_DIR_NAME", "MODPACK_NAME", "JAVA_ARGS_CONFIG"];
  for (const key of requiredVars) {
    if (!data[key]) {
      throw new Error(`Missing required variable: ${key}`);
    }
  }

  // Output the variables in a format bash can capture
  console.log(JSON.stringify(data));
  return data;
}

loadVariables();
