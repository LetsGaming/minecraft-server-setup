"use strict";

const path = require("path");
const fs = require("fs");
const loadVariables = require("../common/loadVariables");

const vars = loadVariables();
const {
  TARGET_DIR_NAME,
  INSTANCE_NAME,
  JAVA: {
    SERVER: {
      MAX_PLAYERS,
      MOTD,
      SEED,
      WHITELIST,
      DIFFICULTY,
      PVP,
      FLIGHT_ENABLED,
      ALLOW_CRACKED,
    },
  },
} = vars;

// ── Security: warn loudly when offline mode (cracked clients) is enabled ──
if (ALLOW_CRACKED) {
  const banner = [
    "",
    "╔══════════════════════════════════════════════════════════╗",
    "║  ⚠  SECURITY WARNING: ALLOW_CRACKED is enabled           ║",
    "║                                                           ║",
    "║  online-mode=false will be written to server.properties.  ║",
    "║  This disables Mojang authentication — ANY client can     ║",
    "║  connect using any username, including impersonating       ║",
    "║  existing players (bypasses whitelist by name).           ║",
    "║                                                           ║",
    "║  Only enable this on a private LAN with trusted players.  ║",
    "║  Set ALLOW_CRACKED: false in variables.json to disable.   ║",
    "╚══════════════════════════════════════════════════════════╝",
    "",
  ].join("\n");
  process.stderr.write(banner + "\n");
}

// Optional RCON config
const serverControl = vars.SERVER_CONTROL || {};

const MODPACK_DIR = path.join(
  process.env.MAIN_DIR,
  TARGET_DIR_NAME,
  "instances",
  INSTANCE_NAME,
);
const serverPropsPath = path.join(MODPACK_DIR, "server.properties");

function updateServerProperties() {
  if (!fs.existsSync(serverPropsPath)) {
    fs.writeFileSync(serverPropsPath, "", "utf-8");
  }

  let content = fs.readFileSync(serverPropsPath, "utf-8");

  const updates = {
    "max-players": MAX_PLAYERS,
    // server.properties is a Java .properties file: the value runs to the end
    // of the line and quotes are literal, so escaping " as \" (as before) would
    // show a literal backslash in-game. Just strip newlines/CR, which would
    // otherwise truncate or corrupt the line.
    motd: String(MOTD).replace(/\r?\n/g, ""),
    "level-seed": SEED,
    "white-list": WHITELIST,
    difficulty: DIFFICULTY,
    pvp: PVP,
    "allow-flight": FLIGHT_ENABLED,
    "online-mode": !ALLOW_CRACKED,
  };

  // Add RCON settings if enabled
  if (serverControl.USE_RCON) {
    updates["enable-rcon"] = true;
    updates["rcon.port"] = serverControl.RCON_PORT || 25575;
    updates["rcon.password"] = serverControl.RCON_PASSWORD || "";
  }

  for (const [key, value] of Object.entries(updates)) {
    const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const regex = new RegExp(`^${escapedKey}=.*$`, "m");
    const line = `${key}=${value}`;
    if (regex.test(content)) {
      content = content.replace(regex, line);
    } else {
      content += `\n${line}`;
    }
  }

  fs.writeFileSync(serverPropsPath, content, "utf-8");

  const rconStatus = serverControl.USE_RCON ? " (RCON enabled)" : "";
  console.log(`Updated server.properties${rconStatus}.`);
}

updateServerProperties();
