const path = require("path");
const fs = require("fs");
const loadVariables = require("../common/loadVariables");

const {
  TARGET_DIR_NAME,
  MODPACK_NAME,
  JAVA: {
    JAVA_ARGS_CONFIG,
  }
} = loadVariables();

const MODPACK_DIR = path.join(process.env.MAIN_DIR, TARGET_DIR_NAME, MODPACK_NAME);
const variablesTxtPath = path.join(MODPACK_DIR, "variables.txt");

function buildJavaArgs(config) {
  const flags = [];

  // Memory settings
  if (config.minMemory) flags.push(`-Xms${config.minMemory}`);
  if (config.maxMemory) flags.push(`-Xmx${config.maxMemory}`);
  if (config.metaspaceLimit) flags.push(`-XX:MaxMetaspaceSize=${config.metaspaceLimit}`);

  const gcChoice = config.garbageCollector;
  if (!gcChoice || !["g1gc", "zgc"].includes(gcChoice)) {
    throw new Error("Invalid or missing garbageCollector (must be 'g1gc' or 'zgc').");
  }

  // GC Flags
  if (gcChoice === "g1gc") {
    flags.push("-XX:+UseG1GC");
    const g1gc = config.g1gc || {};

    // Collect experimental G1 options
    const experimentalFlags = [];
    if (g1gc.g1NewSizePercent) experimentalFlags.push(`-XX:G1NewSizePercent=${g1gc.g1NewSizePercent}`);
    if (g1gc.g1MaxNewSizePercent) experimentalFlags.push(`-XX:G1MaxNewSizePercent=${g1gc.g1MaxNewSizePercent}`);

    // If experimental flags are present, unlock experimental options first
    if (experimentalFlags.length > 0) {
      flags.push("-XX:+UnlockExperimentalVMOptions");
      flags.push(...experimentalFlags);
    }

    if (g1gc.maxPauseMillis) flags.push(`-XX:MaxGCPauseMillis=${g1gc.maxPauseMillis}`);
    if (g1gc.heapRegionSize) flags.push(`-XX:G1HeapRegionSize=${g1gc.heapRegionSize}`);
    if (g1gc.reservePercent) flags.push(`-XX:G1ReservePercent=${g1gc.reservePercent}`);
    if (g1gc.heapWastePercent) flags.push(`-XX:G1HeapWastePercent=${g1gc.heapWastePercent}`);
    if (g1gc.mixedGCCountTarget) flags.push(`-XX:G1MixedGCCountTarget=${g1gc.mixedGCCountTarget}`);
    if (g1gc.initiatingHeapOccupancyPercent) flags.push(`-XX:InitiatingHeapOccupancyPercent=${g1gc.initiatingHeapOccupancyPercent}`);
    if (g1gc.survivorRatio) flags.push(`-XX:SurvivorRatio=${g1gc.survivorRatio}`);
    if (g1gc.parallelRefProcEnabled) flags.push("-XX:+ParallelRefProcEnabled");
    if (g1gc.disableExplicitGC) flags.push("-XX:+DisableExplicitGC");
    if (g1gc.alwaysPreTouch) flags.push("-XX:+AlwaysPreTouch");
    if (g1gc.perfDisableSharedMem) flags.push("-XX:+PerfDisableSharedMem");

  } else if (gcChoice === "zgc") {
    flags.push("-XX:+UseZGC", "-XX:+UnlockExperimentalVMOptions");
    const zgc = config.zgc || {};
    if (zgc.uncommitDelay) flags.push(`-XX:ZUncommitDelay=${zgc.uncommitDelay}`);
    if (zgc.uncommitDelayOnIdle) flags.push(`-XX:ZUncommitDelayOnIdle=${zgc.uncommitDelayOnIdle}`);
    if (zgc.heapReservePercent) flags.push(`-XX:ZHeapReservePercent=${zgc.heapReservePercent}`);
    if (zgc.concurrentGCThreads) flags.push(`-XX:ConcGCThreads=${zgc.concurrentGCThreads}`);
    if (zgc.softMaxHeapSize) flags.push(`-XX:SoftMaxHeapSize=${zgc.softMaxHeapSize}`);
  }

  // String Deduplication flag
  if (config.enableStringDeduplication) flags.push("-XX:+UseStringDeduplication");

  // Misc flags
  if (Array.isArray(config.miscFlags)) {
    flags.push(...config.miscFlags);
  }

  return flags.join(" ");
}

function updateJavaArgsInVariablesFile() {
  if (!JAVA_ARGS_CONFIG) {
    throw new Error("Missing JAVA_ARGS_CONFIG in variables.json");
  }

  const javaArgsString = `"${buildJavaArgs(JAVA_ARGS_CONFIG)}"`; // wrap in quotes

  if (!fs.existsSync(variablesTxtPath)) {
    throw new Error(`variables.txt not found at ${variablesTxtPath}`);
  }

  let variablesContent = fs.readFileSync(variablesTxtPath, "utf-8");

  const regex = /^JAVA_ARGS=.*$/m;
  if (regex.test(variablesContent)) {
    variablesContent = variablesContent.replace(regex, `JAVA_ARGS=${javaArgsString}`);
  } else {
    variablesContent += `\nJAVA_ARGS=${javaArgsString}`;
  }

  fs.writeFileSync(variablesTxtPath, variablesContent, "utf-8");
  console.log("JAVA_ARGS updated in variables.txt.");
}

updateJavaArgsInVariablesFile();
