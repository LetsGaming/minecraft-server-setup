const { execSync } = require("child_process");
const JAVA = require("../../variables.json").JAVA;

function parseMinecraftVersion(version) {
  return version.split(".").map((v) => parseInt(v, 10));
}

function getRequiredJavaVersion(mcVersion) {
  if(mcVersion === "latest") {
    return 21; // Default to the latest Java version for the latest Minecraft version
  }
  const [major, minor, patch = 0] = parseMinecraftVersion(mcVersion);

  if (major === 1 && minor === 20 && patch >= 5) return 21;
  if (major === 1 && minor === 20 && patch <= 4) return 18;
  if (major === 1 && minor === 19) return 18;
  if (major === 1 && minor === 18) {
    return patch === 2 ? 18 : 17;
  }
  if (major === 1 && minor === 17) return 17;
  if (major === 1 && minor <= 16) return 11;

  throw new Error(
    `Don't know which Java version to use for Minecraft ${mcVersion}`
  );
}

function getCurrentJavaVersion() {
  try {
    const output = execSync("java -version 2>&1").toString();
    const match = output.match(/version "(.*?)"/);
    if (!match) return null;

    const versionStr = match[1];
    if (versionStr.startsWith("1.")) {
      return parseInt(versionStr.split(".")[1], 10); // e.g., 1.8 => 8
    } else {
      return parseInt(versionStr.split(".")[0], 10); // e.g., 17.0.1 => 17
    }
  } catch {
    return null;
  }
}

function isJavaVersionInstalledWithJabba(requiredVersion) {
  try {
    const list = execSync("jabba ls").toString();
    return list.includes(`adopt@${requiredVersion}`);
  } catch {
    return false;
  }
}

function installWithJabba(requiredVersion) {
  const jabbaVersion = `adopt@${requiredVersion}`;
  try {
    if (!isJavaVersionInstalledWithJabba(requiredVersion)) {
      console.log(`Installing Java ${requiredVersion} with Jabba...`);
      execSync(`jabba install ${jabbaVersion}`, { stdio: "inherit" });
    } else {
      console.log(`Java ${requiredVersion} is already installed with Jabba.`);
    }

    console.log(`Activating Java ${requiredVersion} using Jabba...`);
    execSync(`jabba use ${jabbaVersion}`, { stdio: "inherit" });
  } catch (err) {
    console.error(
      `Failed to install/use Java ${requiredVersion} via Jabba:`,
      err.message
    );
    process.exit(1);
  }
}

function ensureJavaVersion() {
  const minecraftVersion = JAVA.SERVER.VANILLA.VERSION;
  const requiredJava = getRequiredJavaVersion(minecraftVersion);
  const currentJava = getCurrentJavaVersion();

  console.log(`Minecraft ${minecraftVersion} requires Java ${requiredJava}`);
  if (currentJava) {
    console.log(`Current Java version: ${currentJava}`);
  } else {
    console.warn("Java is not installed or not in PATH.");
  }

  if (!currentJava || currentJava < requiredJava) {
    installWithJabba(requiredJava);
  } else {
    console.log("Required Java version is already installed.");
  }
}

ensureJavaVersion()
