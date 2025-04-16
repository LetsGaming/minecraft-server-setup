const path = require("path");
const fs = require("fs");

function loadVariables() {
  const variablesPath = path.resolve(__dirname, "../variables.json");
  if (!fs.existsSync(variablesPath)) {
    throw new Error(`Missing variables.json at expected path: ${variablesPath}`);
  }

  const data = JSON.parse(fs.readFileSync(variablesPath, "utf-8"));

  // Validate the root structure and required fields
  const requiredVars = [
    "TARGET_DIR_NAME",
    "MODPACK_NAME",
    "JAVA"
  ];

  for (const key of requiredVars) {
    if (!data[key]) {
      throw new Error(`Missing required variable: ${key}`);
    }
  }

  // Validate JAVA object structure
  const javaConfig = data.JAVA;

  if (!javaConfig.SERVER) {
    throw new Error('Missing "SERVER" configuration under "JAVA"');
  }

  const serverVars = [
    "MAX_PLAYERS",
    "MOTD",
    "WHITELIST",
    "SEED",
    "DIFFICULTY",
    "PVP",
    "FLIGHT_ENABLED",
    "ALLOW_CRACKED"
  ];

  for (const key of serverVars) {
    if (javaConfig.SERVER[key] === undefined) {
      throw new Error(`Missing required server property: JAVA.SERVER.${key}`);
    }
  }

  // Validate JAVA_ARGS_CONFIG structure
  const javaArgsConfig = javaConfig.JAVA_ARGS_CONFIG;
  if (!javaArgsConfig) {
    throw new Error('Missing "JAVA_ARGS_CONFIG" under "JAVA"');
  }

  const javaArgsRequiredVars = [
    "minMemory",
    "maxMemory",
    "metaspaceLimit",
    "garbageCollector"
  ];

  for (const key of javaArgsRequiredVars) {
    if (javaArgsConfig[key] === undefined) {
      throw new Error(`Missing required property: JAVA.JAVA_ARGS_CONFIG.${key}`);
    }
  }

  // Validate garbage collector settings if present
  const gcConfig = javaArgsConfig.garbageCollector;
  if (gcConfig === "g1gc") {
    const g1gcArgs = javaArgsConfig.g1gc;
    if (!g1gcArgs) {
      throw new Error('Missing "g1gc" configuration under "JAVA_ARGS_CONFIG"');
    }
    const g1gcRequiredVars = [
      "maxPauseMillis",
      "g1NewSizePercent",
      "g1MaxNewSizePercent",
      "heapRegionSize",
      "reservePercent",
      "heapWastePercent",
      "mixedGCCountTarget",
      "initiatingHeapOccupancyPercent",
      "survivorRatio",
      "parallelRefProcEnabled",
      "disableExplicitGC",
      "alwaysPreTouch",
      "perfDisableSharedMem"
    ];
    for (const key of g1gcRequiredVars) {
      if (g1gcArgs[key] === undefined) {
        throw new Error(`Missing required property: JAVA.JAVA_ARGS_CONFIG.g1gc.${key}`);
      }
    }
  } else if (gcConfig === "zgc") {
    const zgcArgs = javaArgsConfig.zgc;
    if (!zgcArgs) {
      throw new Error('Missing "zgc" configuration under "JAVA_ARGS_CONFIG"');
    }
    const zgcRequiredVars = [
      "uncommitDelay",
      "uncommitDelayOnIdle",
      "heapReservePercent",
      "concurrentGCThreads",
      "softMaxHeapSize"
    ];
    for (const key of zgcRequiredVars) {
      if (zgcArgs[key] === undefined) {
        throw new Error(`Missing required property: JAVA.JAVA_ARGS_CONFIG.zgc.${key}`);
      }
    }
  }

  // Validate miscFlags array
  if (Array.isArray(javaArgsConfig.miscFlags)) {
    javaArgsConfig.miscFlags.forEach(flag => {
      if (typeof flag !== 'string') {
        throw new Error('All items in "miscFlags" should be strings.');
      }
    });
  }

  return data;
}

module.exports = loadVariables;