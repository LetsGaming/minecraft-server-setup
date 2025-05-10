const { execSync } = require("child_process");
const { JAVA } = require("../../variables.json");
const { getJavaVersionFor } = require("../../setup/download/download_utils.js");

function getLatestJabbaCandidate(javaVersion) {
  try {
    const listOutput = execSync(
      `bash -c '. ~/.jabba/jabba.sh && jabba ls-remote'`,
      { encoding: "utf8" }
    );
    const versions = listOutput
      .split("\n")
      .map((line) => line.trim())
      .filter(
        (line) =>
          line.startsWith(`adopt@` + javaVersion + `.`) ||
          line.startsWith(`temurin@` + javaVersion + `.`)
      );
    if (versions.length === 0)
      throw new Error(`No Jabba candidates found for Java ${javaVersion}`);
    // Use the latest available
    return versions.sort().reverse()[0];
  } catch (err) {
    console.error(`Failed to fetch remote Jabba versions: ${err.message}`);
    process.exit(1);
  }
}

function installJava(candidate) {
  try {
    console.log(`Installing Java version: ${candidate}`);
    execSync(
      `bash -c '. ~/.jabba/jabba.sh && jabba install ${candidate} && jabba use ${candidate}'`,
      { stdio: "inherit" }
    );
    console.log(`Java ${candidate} installed and activated.`);
  } catch (err) {
    console.error(`Java installation failed: ${err.message}`);
    process.exit(1);
  }
}

// Entry point
const mcVersion = JAVA.SERVER.VANILLA.VERSION;
if (!mcVersion) {
  console.error(
    "Minecraft version not specified in JAVA.SERVER.VANILLA.VERSION"
  );
  process.exit(1);
}

try {
  const javaVersion = getJavaVersionFor(mcVersion);
  const jabbaCandidate = getLatestJabbaCandidate(javaVersion);
  installJava(jabbaCandidate);
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
