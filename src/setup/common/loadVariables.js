const path = require("path");
const fs = require("fs");

const VALID_DIFFICULTIES = ["peaceful", "easy", "normal", "hard"];
const VALID_GC = ["g1gc", "zgc"];
const MEMORY_PATTERN = /^\d+[GMK]$/i;
/** Placeholders shipped in variables.example.json; never a real key. */
const EXAMPLE_API_KEYS = ["replace-with-a-long-random-secret"];
/** Every event the scripts send; the README documents the same list. */
const KNOWN_WEBHOOK_EVENTS = [
  "backup_complete",
  "backup_failed",
  "backup_skipped",
  "server_start",
  "server_start_failed",
  "server_stop",
  "server_restart",
  "server_crash_loop",
  "rollback_start",
  "rollback_complete",
  "update_start",
  "update_complete",
  "update_failed",
  "storage_warning",
  "mirror_export_failed",
  "mirror_sync_complete",
  "mirror_sync_failed",
];

function loadVariables() {
  const variablesPath = path.resolve(__dirname, "..", "..", "..", "variables.json");
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

  // TARGET_DIR_NAME becomes $HOME/<name>, the root every instance lives
  // under. "." or ".." would make that $HOME or its parent (S-001).
  if (!/^[a-zA-Z0-9_-]+$/.test(data.TARGET_DIR_NAME)) {
    throw new Error('TARGET_DIR_NAME must only contain letters, numbers, hyphens, and underscores.');
  }

  // ── BACKUPS ──
  const backups = data.BACKUPS;
  // These land in shell arithmetic and zstd flags in the deployed scripts, so a
  // fraction or a string would break backups and cleanup at run time.
  if (!Number.isInteger(backups.COMPRESSION_LEVEL) || backups.COMPRESSION_LEVEL < 1 || backups.COMPRESSION_LEVEL > 19) {
    throw new Error("BACKUPS.COMPRESSION_LEVEL must be a whole number between 1 and 19.");
  }
  if (!Number.isInteger(backups.MAX_STORAGE_GB) || backups.MAX_STORAGE_GB < 1) {
    throw new Error("BACKUPS.MAX_STORAGE_GB must be a positive whole number.");
  }
  for (const key of ["MAX_HOURLY_BACKUPS", "MAX_DAILY_BACKUPS", "MAX_WEEKLY_BACKUPS", "MAX_MONTHLY_BACKUPS"]) {
    if (!Number.isInteger(backups[key]) || backups[key] < 0) {
      throw new Error(`BACKUPS.${key} must be a non-negative whole number.`);
    }
  }
  if (backups.MAX_UPDATE_BACKUPS !== undefined && (!Number.isInteger(backups.MAX_UPDATE_BACKUPS) || backups.MAX_UPDATE_BACKUPS < 1)) {
    throw new Error("BACKUPS.MAX_UPDATE_BACKUPS must be a positive whole number when set.");
  }
  // Optional tuning keys; each one has a default in the shell scripts.
  const optionalInts = {
    MAX_CUSTOM_BACKUPS: [0, null],
    BACKUP_HOURLY_LEVEL: [1, 19],
    BACKUP_ARCHIVE_LEVEL: [1, 19],
    BACKUP_ZSTD_THREADS: [0, 256],
    BACKUP_SPACE_MARGIN_PCT: [0, 50],
    BACKUP_TIMEOUT_MINUTES: [1, null],
    BACKUP_SKIP_ALERT_AFTER: [1, null],
    BACKUP_ARCHIVE_MAX_ATTEMPTS: [1, null],
    BACKUP_LOG_MAX_MB: [1, null],
    RESTORE_KEEP_OLD_DAYS: [0, null],
  };
  for (const [key, [min, max]] of Object.entries(optionalInts)) {
    const value = backups[key];
    if (value === undefined) continue;
    if (!Number.isInteger(value) || value < min || (max !== null && value > max)) {
      throw new Error(`BACKUPS.${key} must be a whole number${max !== null ? ` between ${min} and ${max}` : ` of at least ${min}`} when set.`);
    }
  }
  if (backups.BACKUP_STAGING_MODE !== undefined && !["auto", "mirror", "reflink", "fresh"].includes(backups.BACKUP_STAGING_MODE)) {
    throw new Error("BACKUPS.BACKUP_STAGING_MODE must be one of auto, mirror, reflink or fresh when set.");
  }
  for (const key of ["BACKUP_FOLLOW_SYMLINKS", "RESTORE_KEEP_OLD"]) {
    if (backups[key] !== undefined && typeof backups[key] !== "boolean") {
      throw new Error(`BACKUPS.${key} must be true or false when set.`);
    }
  }
  for (const key of ["BACKUP_EXTRA_EXCLUDES", "RESTORE_CARRY_OVER"]) {
    if (backups[key] !== undefined && typeof backups[key] !== "string") {
      throw new Error(`BACKUPS.${key} must be a string of space-separated names when set.`);
    }
  }

  // ── API_SERVER (optional) ──
  if (data.API_SERVER) {
    const api = data.API_SERVER;
    if (api.ENABLED !== undefined && typeof api.ENABLED !== 'boolean') {
      throw new Error('API_SERVER.ENABLED must be a boolean.');
    }
    if (api.PORT !== undefined) {
      if (typeof api.PORT !== 'number' || api.PORT < 1 || api.PORT > 65535) {
        throw new Error('API_SERVER.PORT must be a valid port number (1–65535).');
      }
    }
    if (api.API_KEY !== undefined && typeof api.API_KEY !== 'string') {
      throw new Error('API_SERVER.API_KEY must be a string.');
    }
    if (api.SERVICE_USER !== undefined && api.SERVICE_USER !== "" && !/^[a-z_][a-z0-9_-]{0,31}$/.test(String(api.SERVICE_USER))) {
      throw new Error("API_SERVER.SERVICE_USER must be a Linux user name (lowercase letters, digits, - and _).");
    }
    // S-018: the example's placeholder is 33 characters, so the length check
    // let an install run with a key printed in this repository.
    if (api.ENABLED && api.API_KEY && EXAMPLE_API_KEYS.includes(api.API_KEY)) {
      throw new Error(
        "API_SERVER.API_KEY is still the example's placeholder. Generate a real one with: openssl rand -hex 32",
      );
    }
    if (api.ENABLED && api.API_KEY && api.API_KEY.length < 32) {
      throw new Error(
        `API_SERVER.API_KEY is ${api.API_KEY.length} characters; the API wrapper refuses to start with fewer than 32. Generate one with: openssl rand -hex 32`,
      );
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
    for (const event of notif.WEBHOOK_EVENTS || []) {
      if (!KNOWN_WEBHOOK_EVENTS.includes(event)) {
        process.stderr.write(
          `[WARN] NOTIFICATIONS.WEBHOOK_EVENTS lists "${event}", which no script sends.
` +
          `       Known events: ${KNOWN_WEBHOOK_EVENTS.join(", ")}.
`
        );
      }
    }
  }

  // ── RESTART_SCHEDULE (optional) ──
  if (data.RESTART_SCHEDULE) {
    const rs = data.RESTART_SCHEDULE;
    if (rs.INTERVAL_HOURS !== undefined) {
      const h = rs.INTERVAL_HOURS;
      // cron's "*/N" hour field restarts its count at midnight, so only a
      // divisor of 24 gives an even interval; a multiple of 24 is whole days.
      if (!Number.isInteger(h) || h < 1 || (h <= 24 ? 24 % h !== 0 : h % 24 !== 0)) {
        throw new Error(
          "RESTART_SCHEDULE.INTERVAL_HOURS must be a whole number of hours that divides 24 (1, 2, 3, 4, 6, 8, 12, 24) or is a multiple of 24.",
        );
      }
    }
    if (rs.WARN_SECONDS !== undefined && (typeof rs.WARN_SECONDS !== "number" || rs.WARN_SECONDS < 5)) {
      throw new Error("RESTART_SCHEDULE.WARN_SECONDS must be at least 5.");
    }
  }

  // ── MIRROR (optional; nothing else depends on it) ──
  if (data.MIRROR) {
    const mirror = data.MIRROR;
    if (typeof mirror !== "object" || Array.isArray(mirror)) throw new Error("MIRROR must be an object.");
    if (mirror.ENABLED !== undefined && typeof mirror.ENABLED !== "boolean") {
      throw new Error("MIRROR.ENABLED must be a boolean.");
    }
    if (mirror.ROLE !== undefined && mirror.ROLE !== "source" && mirror.ROLE !== "target") {
      throw new Error('MIRROR.ROLE must be "source" (the survival server) or "target" (the creative server).');
    }
    if (mirror.ENABLED && !mirror.ROLE) {
      throw new Error('MIRROR.ROLE is required when MIRROR.ENABLED is true ("source" or "target").');
    }
    if (mirror.REMOTE !== undefined && mirror.REMOTE !== "" && !/^mcsync@[A-Za-z0-9._:-]+$/.test(String(mirror.REMOTE))) {
      throw new Error("MIRROR.REMOTE must look like mcsync@host (the survival server's read-only account).");
    }
    if (mirror.ENABLED && mirror.ROLE === "target" && !mirror.REMOTE) {
      throw new Error("MIRROR.REMOTE (mcsync@host of the survival server) is required for a target.");
    }
    if (mirror.SSH_PORT !== undefined && (!Number.isInteger(mirror.SSH_PORT) || mirror.SSH_PORT < 1 || mirror.SSH_PORT > 65535)) {
      throw new Error("MIRROR.SSH_PORT must be a valid port number (1-65535).");
    }
    if (mirror.SOURCE_MODE !== undefined && mirror.SOURCE_MODE !== "live" && mirror.SOURCE_MODE !== "stage") {
      throw new Error('MIRROR.SOURCE_MODE must be "live" or "stage".');
    }
    if (mirror.DIMS !== undefined) {
      const allowed = ["minecraft/overworld", "minecraft/the_nether", "minecraft/the_end"];
      if (!Array.isArray(mirror.DIMS) || mirror.DIMS.length === 0 || mirror.DIMS.some((d) => !allowed.includes(d))) {
        throw new Error(`MIRROR.DIMS must be a non-empty list of ${allowed.join(", ")}.`);
      }
    }
    for (const key of ["EXPORT_AT", "PULL_AT"]) {
      if (mirror[key] !== undefined && !/^([01]\d|2[0-3]):[0-5]\d$/.test(String(mirror[key]))) {
        throw new Error(`MIRROR.${key} must be a time as HH:MM.`);
      }
    }
    if (mirror.PARITY !== undefined && !["warn", "refuse", "off"].includes(mirror.PARITY)) {
      throw new Error('MIRROR.PARITY must be "warn", "refuse" or "off".');
    }
    for (const key of ["BWLIMIT_KIB", "MAX_SNAPSHOT_GB"]) {
      if (mirror[key] !== undefined && (!Number.isInteger(mirror[key]) || mirror[key] < 0)) {
        throw new Error(`MIRROR.${key} must be a whole number of 0 or more.`);
      }
    }
    if (mirror.MIN_REGION_RATIO_PCT !== undefined && (!Number.isInteger(mirror.MIN_REGION_RATIO_PCT) || mirror.MIN_REGION_RATIO_PCT < 0 || mirror.MIN_REGION_RATIO_PCT > 100)) {
      throw new Error("MIRROR.MIN_REGION_RATIO_PCT must be a whole number from 0 to 100.");
    }
    if (mirror.EXTRAS !== undefined) {
      const deny = /^(dimensions|players|playerdata|advancements|stats|data|datapacks|region|entities|poi|dimensional-inventories|level\.dat.*|session\.lock|\.|\.\.)$/;
      if (!Array.isArray(mirror.EXTRAS) || mirror.EXTRAS.some((x) => typeof x !== "string" || !/^[A-Za-z0-9_.-]+$/.test(x) || deny.test(x))) {
        throw new Error("MIRROR.EXTRAS must be a list of plain world folder names that are not server state (for example modplayerdata).");
      }
    }
    for (const key of ["SYNC_MODS", "EXPORT_MODS", "PERMISSIONS"]) {
      if (mirror[key] !== undefined && typeof mirror[key] !== "boolean") {
        throw new Error(`MIRROR.${key} must be a boolean.`);
      }
    }
    if (mirror.KEEP_SNAPSHOTS !== undefined && (!Number.isInteger(mirror.KEEP_SNAPSHOTS) || mirror.KEEP_SNAPSHOTS < 2)) {
      throw new Error("MIRROR.KEEP_SNAPSHOTS must be at least 2 so a pull in progress never loses its snapshot.");
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

  if (javaConfig.SERVER.PORT !== undefined) {
    const port = javaConfig.SERVER.PORT;
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error("JAVA.SERVER.PORT must be a valid port number (1-65535).");
    }
  }

  const excluded = javaConfig.SERVER.VANILLA?.MODS?.EXCLUDE;
  if (excluded !== undefined && (!Array.isArray(excluded) || excluded.some((slug) => typeof slug !== "string"))) {
    throw new Error("JAVA.SERVER.VANILLA.MODS.EXCLUDE must be an array of mod slugs.");
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

  // Validate configured heap against available system memory (Linux only).
  // A maxMemory larger than MemAvailable causes the JVM to fail at startup
  // with a cryptic native OOM error. We warn here so the operator can adjust
  // the value before the server launch attempt.
  if (process.platform === "linux") {
    try {
      const memInfoRaw = require("fs").readFileSync("/proc/meminfo", "utf-8");
      const match = memInfoRaw.match(/^MemAvailable:\s+(\d+)\s+kB/m);
      if (match) {
        const availableKb  = parseInt(match[1], 10);
        const availableMb  = Math.floor(availableKb / 1024);

        // Convert configured maxMemory to MB for comparison
        const maxMemStr    = javaArgsConfig.maxMemory.toUpperCase();
        const maxMemVal    = parseInt(maxMemStr, 10);
        const maxMemMb     = maxMemStr.endsWith("G") ? maxMemVal * 1024
                          : maxMemStr.endsWith("M") ? maxMemVal
                          : Math.floor(maxMemVal / 1024);

        if (maxMemMb > availableMb) {
          process.stderr.write(
            `[WARN] JAVA.JAVA_ARGS_CONFIG.maxMemory (${javaArgsConfig.maxMemory}) exceeds ` +
            `available system memory (${availableMb} MB free). ` +
            "The JVM will likely fail to start. Lower maxMemory in variables.json.\n"
          );
        }
      }
    } catch {
      // /proc/meminfo unavailable — skip the check silently
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
module.exports.KNOWN_WEBHOOK_EVENTS = KNOWN_WEBHOOK_EVENTS;
