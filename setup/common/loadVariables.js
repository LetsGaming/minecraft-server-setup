const path = require("path");
const fs = require("fs");

const VALID_DIFFICULTIES = ["peaceful", "easy", "normal", "hard"];
const VALID_GC = ["g1gc", "zgc"];
const MEMORY_PATTERN = /^\d+[GMK]$/i;

function loadVariables() {
  const variablesPath = path.resolve(__dirname, "..", "..", "variables.json");
  if (!fs.existsSync(variablesPath)) {
    throw new Error(`Missing variables.json at expected path: ${variablesPath}`);
  }

  const data = JSON.parse(fs.readFileSync(variablesPath, "utf-8"));

  // ── Root structure ──
  const requiredVars = ["INSTANCE_NAME", "TARGET_DIR_NAME", "BACKUPS", "JAVA"];
  for (const key of requiredVars) {
    if (!data[key]) {
      throw new Error(`Missing required variable: ${key}`);
    }
  }

  // Validate INSTANCE_NAME format (safe for filenames, systemd, screen)
  if (!/^[a-zA-Z0-9_-]+$/.test(data.INSTANCE_NAME)) {
    throw new Error('INSTANCE_NAME must only contain letters, numbers, hyphens, and underscores.');
  }

  // ── BACKUPS ──
  const backups = data.BACKUPS;
  if (typeof backups.COMPRESSION_LEVEL !== "number" || backups.COMPRESSION_LEVEL < 1 || backups.COMPRESSION_LEVEL > 19) {
    throw new Error("BACKUPS.COMPRESSION_LEVEL must be a number between 1 and 19.");
  }
  if (typeof backups.MAX_STORAGE_GB !== "number" || backups.MAX_STORAGE_GB < 1) {
    throw new Error("BACKUPS.MAX_STORAGE_GB must be a positive number.");
  }
  for (const key of ["MAX_HOURLY_BACKUPS", "MAX_DAILY_BACKUPS", "MAX_WEEKLY_BACKUPS", "MAX_MONTHLY_BACKUPS"]) {
    if (typeof backups[key] !== "number" || backups[key] < 0) {
      throw new Error(`BACKUPS.${key} must be a non-negative number.`);
    }
  }

  // ── SERVER_CONTROL (optional) ──
  if (data.SERVER_CONTROL) {
    const sc = data.SERVER_CONTROL;
    if (sc.USE_RCON && typeof sc.USE_RCON !== "boolean") {
      throw new Error("SERVER_CONTROL.USE_RCON must be a boolean.");
    }
    if (sc.RCON_PORT !== undefined) {
      if (typeof sc.RCON_PORT !== "number" || sc.RCON_PORT < 1 || sc.RCON_PORT > 65535) {
        throw new Error("SERVER_CONTROL.RCON_PORT must be a valid port number (1-65535).");
      }
    }
  }

  // ── NOTIFICATIONS (optional) ──
  if (data.NOTIFICATIONS) {
    const notif = data.NOTIFICATIONS;
    if (notif.WEBHOOK_URL && typeof notif.WEBHOOK_URL !== "string") {
      throw new Error("NOTIFICATIONS.WEBHOOK_URL must be a string.");
    }
    if (notif.WEBHOOK_EVENTS && !Array.isArray(notif.WEBHOOK_EVENTS)) {
      throw new Error("NOTIFICATIONS.WEBHOOK_EVENTS must be an array.");
    }
  }

  // ── RESTART_SCHEDULE (optional) ──
  if (data.RESTART_SCHEDULE) {
    const rs = data.RESTART_SCHEDULE;
    if (rs.INTERVAL_HOURS !== undefined && (typeof rs.INTERVAL_HOURS !== "number" || rs.INTERVAL_HOURS < 1)) {
      throw new Error("RESTART_SCHEDULE.INTERVAL_HOURS must be a positive number.");
    }
    if (rs.WARN_SECONDS !== undefined && (typeof rs.WARN_SECONDS !== "number" || rs.WARN_SECONDS < 5)) {
      throw new Error("RESTART_SCHEDULE.WARN_SECONDS must be at least 5.");
    }
  }

  // ── JAVA.SERVER ──
  const javaConfig = data.JAVA;
  if (!javaConfig.SERVER) {
    throw new Error('Missing "SERVER" configuration under "JAVA"');
  }

  const serverVars = ["MAX_PLAYERS", "MOTD", "WHITELIST", "SEED", "DIFFICULTY", "PVP", "FLIGHT_ENABLED", "ALLOW_CRACKED"];
  for (const key of serverVars) {
    if (javaConfig.SERVER[key] === undefined) {
      throw new Error(`Missing required server property: JAVA.SERVER.${key}`);
    }
  }

  // Validate specific server values
  if (typeof javaConfig.SERVER.MAX_PLAYERS !== "number" || javaConfig.SERVER.MAX_PLAYERS < 1) {
    throw new Error("JAVA.SERVER.MAX_PLAYERS must be a positive number.");
  }
  if (!VALID_DIFFICULTIES.includes(javaConfig.SERVER.DIFFICULTY)) {
    throw new Error(`JAVA.SERVER.DIFFICULTY must be one of: ${VALID_DIFFICULTIES.join(", ")}`);
  }

  // ── JAVA_ARGS_CONFIG ──
  const javaArgsConfig = javaConfig.JAVA_ARGS_CONFIG;
  if (!javaArgsConfig) {
    throw new Error('Missing "JAVA_ARGS_CONFIG" under "JAVA"');
  }

  const javaArgsRequiredVars = ["minMemory", "maxMemory", "metaspaceLimit", "garbageCollector"];
  for (const key of javaArgsRequiredVars) {
    if (javaArgsConfig[key] === undefined) {
      throw new Error(`Missing required property: JAVA.JAVA_ARGS_CONFIG.${key}`);
    }
  }

  // Validate memory format
  for (const memKey of ["minMemory", "maxMemory", "metaspaceLimit"]) {
    if (!MEMORY_PATTERN.test(javaArgsConfig[memKey])) {
      throw new Error(`JAVA.JAVA_ARGS_CONFIG.${memKey} must match format like "12G", "512M", "1024K". Got: "${javaArgsConfig[memKey]}"`);
    }
  }

  // Validate GC choice
  const gcConfig = javaArgsConfig.garbageCollector;
  if (!VALID_GC.includes(gcConfig)) {
    throw new Error(`JAVA.JAVA_ARGS_CONFIG.garbageCollector must be one of: ${VALID_GC.join(", ")}`);
  }

  // Validate GC-specific settings
  if (gcConfig === "g1gc") {
    const g1gcArgs = javaArgsConfig.g1gc;
    if (!g1gcArgs) {
      throw new Error('Missing "g1gc" configuration under "JAVA_ARGS_CONFIG"');
    }
    const g1gcRequiredVars = [
      "maxPauseMillis", "g1NewSizePercent", "g1MaxNewSizePercent", "heapRegionSize",
      "reservePercent", "heapWastePercent", "mixedGCCountTarget",
      "initiatingHeapOccupancyPercent", "survivorRatio", "parallelRefProcEnabled",
      "disableExplicitGC", "alwaysPreTouch", "perfDisableSharedMem"
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
    const zgcRequiredVars = ["uncommitDelay", "uncommitDelayOnIdle", "heapReservePercent", "concurrentGCThreads", "softMaxHeapSize"];
    for (const key of zgcRequiredVars) {
      if (zgcArgs[key] === undefined) {
        throw new Error(`Missing required property: JAVA.JAVA_ARGS_CONFIG.zgc.${key}`);
      }
    }
  }

  // Validate miscFlags
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
