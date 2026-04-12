const path = require("path");
const fs = require("fs");
const loadVariables = require("../common/loadVariables");

const vars = loadVariables();
const {
  TARGET_DIR_NAME,
  INSTANCE_NAME,
  JAVA: {
    SERVER: {
      MAX_PLAYERS, MOTD, SEED, WHITELIST,
      DIFFICULTY, PVP, FLIGHT_ENABLED, ALLOW_CRACKED
    }
  }
} = vars;

// Optional RCON config
const serverControl = vars.SERVER_CONTROL || {};

const MODPACK_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME, INSTANCE_NAME);
const serverPropsPath = path.join(MODPACK_DIR, "server.properties");

function updateServerProperties() {
  if (!fs.existsSync(serverPropsPath)) {
    fs.writeFileSync(serverPropsPath, "", "utf-8");
  }

  let content = fs.readFileSync(serverPropsPath, "utf-8");

  const updates = {
    "max-players": MAX_PLAYERS,
    "motd": MOTD.replace(/\n/g, "").replace(/"/g, '\\"'),
    "level-seed": SEED,
    "white-list": WHITELIST,
    "difficulty": DIFFICULTY,
    "pvp": PVP,
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
    const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
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
