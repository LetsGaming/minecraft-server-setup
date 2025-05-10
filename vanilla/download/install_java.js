const { execSync } = require("child_process");
const JAVA = require("../../variables.json").JAVA;
const path = require("path");

const jabbaShPath = path.join(process.env.HOME, ".jabba", "jabba.sh");

function parseMinecraftVersion(version) {
  return version.split(".").map((v) => parseInt(v, 10));
}

function getRequiredJavaVersion(mcVersion) {
  if (mcVersion === "latest") return 21;
  const [major, minor, patch = 0] = parseMinecraftVersion(mcVersion);

  if (major === 1 && minor === 20 && patch >= 5) return 21;
  if (major === 1 && minor === 20 && patch <= 4) return 18;
  if (major === 1 && minor === 19) return 18;
  if (major === 1 && minor === 18) return patch === 2 ? 18 : 17;
  if (major === 1 && minor === 17) return 17;
  if (major === 1 && minor <= 16) return 11;

  throw new Error(`Don't know which Java version to use for Minecraft ${mcVersion}`);
}

function getCurrentJavaVersion() {
  try {
    const cmd = `bash -c '. ${jabbaShPath} && java -version 2>&1'`;
    const output = execSync(cmd).toString();
    const match = output.match(/version "(.*?)"/);
    if (!match) return null;

    const versionStr = match[1];
    return versionStr.startsWith("1.")
      ? parseInt(versionStr.split(".")[1], 10)
      : parseInt(versionStr.split(".")[0], 10);
  } catch (err) {
    console.error("Error checking Java version:", err.message);
    return null;
  }
}

function isJavaVersionInstalledWithJabba(requiredVersion) {
  try {
    const output = execSync(`. ${jabbaShPath} && jabba ls`, { shell: "/bin/bash" }).toString();
    return output.includes(`temurin@${requiredVersion}`);
  } catch {
    return false;
  }
}

function installWithJabba(requiredVersion) {
  const jabbaVersion = `temurin@${requiredVersion}`;
  try {
    if (!isJavaVersionInstalledWithJabba(requiredVersion)) {
      console.log(`Installing Java ${requiredVersion} with Jabba...`);
      execSync(`. ${jabbaShPath} && jabba install ${jabbaVersion}`, { stdio: "inherit", shell: "/bin/bash" });
    } else {
      console.log(`Java ${requiredVersion} is already installed with Jabba.`);
    }

    console.log(`Activating Java ${requiredVersion} using Jabba...`);
    execSync(`. ${jabbaShPath} && jabba use ${jabbaVersion}`, { stdio: "inherit", shell: "/bin/bash" });
  } catch (err) {
    console.error(`Failed to install/use Java ${requiredVersion} via Jabba:`, err.message);
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

ensureJavaVersion();
