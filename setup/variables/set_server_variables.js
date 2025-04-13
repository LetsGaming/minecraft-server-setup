const fs = require("fs");
const path = require("path");
const loadVariables = require("../common/loadVariables");

const { TARGET_DIR_NAME, MODPACK_NAME, JAVA_ARGS_CONFIG } = loadVariables();

const MODPACK_DIR = path.join(
  process.env.MAIN_DIR,
  TARGET_DIR_NAME,
  MODPACK_NAME
);
const VARIABLES_PATH = path.join(MODPACK_DIR, "variables.txt");

function buildJavaArgs(config) {
  const args = [];

  args.push(`-Xms${config.minMemory}`);
  args.push(`-Xmx${config.maxMemory}`);
  args.push(`-XX:MaxMetaspaceSize=${config.metaspaceLimit}`);

  switch (config.garbageCollector.toLowerCase()) {
    case "zgc":
      args.push("-XX:+UseZGC");
      args.push("-XX:+UnlockExperimentalVMOptions");
      args.push("-XX:+ZUncommit");
      if (config.zgc?.uncommitDelay)
        args.push(`-XX:ZUncommitDelay=${config.zgc.uncommitDelay}`);
      if (config.zgc?.uncommitDelayOnIdle)
        args.push(`-XX:ZUncommitDelayOnIdle=${config.zgc.uncommitDelayOnIdle}`);
      break;

    case "g1gc":
      args.push("-XX:+UseG1GC");
      if (config.enableStringDeduplication)
        args.push("-XX:+UseStringDeduplication");
      if (config.g1gc?.maxPauseMillis)
        args.push(`-XX:MaxGCPauseMillis=${config.g1gc.maxPauseMillis}`);
      if (config.g1gc?.parallelGCThreads)
        args.push(`-XX:ParallelGCThreads=${config.g1gc.parallelGCThreads}`);
      if (config.g1gc?.concGCThreads)
        args.push(`-XX:ConcGCThreads=${config.g1gc.concGCThreads}`);
      break;

    default:
      throw new Error(
        `Unsupported garbageCollector: ${config.garbageCollector}`
      );
  }

  // Optional: suppress RMI GC
  args.push(`-Dsun.rmi.dgc.server.gcInterval=9223372036854775807`);

  return args.join(" ");
}

// Generate the JAVA_ARGS string
const javaArgsString = `"${buildJavaArgs(JAVA_ARGS_CONFIG)}"`;

// Check if variables.txt exists
if (!fs.existsSync(VARIABLES_PATH)) {
  console.error(`Error: ${VARIABLES_PATH} does not exist.`);
  process.exit(1);
}

// Inject into variables.txt
let variablesContent = fs.readFileSync(VARIABLES_PATH, "utf-8");

variablesContent = variablesContent.replace(
  /^JAVA_ARGS=.*$/m,
  `JAVA_ARGS=${javaArgsString}`
);

fs.writeFileSync(VARIABLES_PATH, variablesContent, "utf-8");

console.log(`Injected JAVA_ARGS into ${VARIABLES_PATH}`);
