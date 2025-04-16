const path = require("path");
const fs = require("fs");
const loadVariables = require("./common/loadVariables");

const {
  TARGET_DIR_NAME,
  MODPACK_NAME,
  JAVA: {
    SERVER: {
      MAX_PLAYERS,
      MOTD,
      SEED,
      WHITELIST,
      DIFFICULTY,
      PVP,
      FLIGHT_ENABLED,
      ALLOW_CRACKED
    }
  }
} = loadVariables();

const MODPACK_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME, MODPACK_NAME);
const serverPropsPath = path.join(MODPACK_DIR, "server.properties");

function updateServerProperties() {
  if (!fs.existsSync(serverPropsPath)) {
    throw new Error(`server.properties not found at ${serverPropsPath}`);
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
    "online-mode": ALLOW_CRACKED,
  };

  for (const [key, value] of Object.entries(updates)) {
    const regex = new RegExp(`^${key}=.*$`, "m");
    const line = `${key}=${value}`;
    if (regex.test(content)) {
      content = content.replace(regex, line);
    } else {
      content += `\n${line}`;
    }
  }

  fs.writeFileSync(serverPropsPath, content, "utf-8");
  console.log(`Updated server.properties with max-players, motd, and server settings.`);
}

updateServerProperties();
