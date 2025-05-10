const { execSync } = require("child_process");
const semver = require("semver");
const { JAVA } = require("../../variables.json");

const MINECRAFT_JAVA_MAP = [
  { mc: "1.21", java: "21" },
  { mc: "1.20", java: "17" },
  { mc: "1.18", java: "17" },
  { mc: "1.17", java: "16" },
  { mc: "1.16", java: "8" },
  { mc: "1.12", java: "8" },
];

function getJavaVersionFor(mcVersion) {
  if (mcVersion === "latest") {
    mcVersion = MINECRAFT_JAVA_MAP[0].mc;
  }
  const sorted = MINECRAFT_JAVA_MAP.sort((a, b) =>
    semver.rcompare(semver.coerce(a.mc), semver.coerce(b.mc))
  );
  for (const entry of sorted) {
    if (semver.gte(semver.coerce(mcVersion), semver.coerce(entry.mc))) {
      return entry.java;
    }
  }
  throw new Error(`Unsupported Minecraft version: ${mcVersion}`);
}

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
