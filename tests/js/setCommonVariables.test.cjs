// setup/variables/set_common_variables.js turns variables.json into the deployed
// variables.txt. The optional MIRROR block must reach it only when it is switched
// on, so an install that never heard of the mirror gets the same file as before.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const SRC = path.join(__dirname, "..", "..", "src");

const BASE = {
  INSTANCE_NAME: "survival",
  TARGET_DIR_NAME: "mc",
  BACKUPS: {
    COMPRESSION_LEVEL: 3, MAX_STORAGE_GB: 10, MAX_HOURLY_BACKUPS: 5, MAX_DAILY_BACKUPS: 5,
    MAX_WEEKLY_BACKUPS: 5, MAX_MONTHLY_BACKUPS: 5,
  },
  JAVA: {
    SERVER: { MAX_PLAYERS: 10, MOTD: "m", WHITELIST: false, SEED: "", DIFFICULTY: "normal", PVP: false, FLIGHT_ENABLED: true, ALLOW_CRACKED: false },
    JAVA_ARGS_CONFIG: {
      minMemory: "1M", maxMemory: "1M", metaspaceLimit: "64M", garbageCollector: "zgc",
      zgc: { uncommitDelay: "1h", uncommitDelayOnIdle: "30m", heapReservePercent: 5, concurrentGCThreads: 2, softMaxHeapSize: "1M" },
    },
  },
};

// Runs the real script in a scratch copy of the folders it expects.
function variablesTxt(vars) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "setcommon-"));
  try {
    for (const rel of ["setup/common/loadVariables.js", "setup/variables/set_common_variables.js"]) {
      const dest = path.join(root, "src", rel);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(path.join(SRC, rel), dest);
    }
    fs.mkdirSync(path.join(root, "src", "scripts", "common"), { recursive: true });
    fs.writeFileSync(path.join(root, "variables.json"), JSON.stringify(vars));
    const res = spawnSync(process.execPath, [path.join(root, "src", "setup", "variables", "set_common_variables.js")], {
      env: { ...process.env, MAIN_DIR: root },
      encoding: "utf8",
    });
    assert.equal(res.status, 0, res.stderr);
    return fs.readFileSync(path.join(root, "src", "scripts", "common", "variables.txt"), "utf8");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("an install without a mirror gets no MIRROR_ line, whether the block is absent or off", () => {
  assert.doesNotMatch(variablesTxt(BASE), /MIRROR_/);
  assert.doesNotMatch(variablesTxt({ ...BASE, MIRROR: { ENABLED: false } }), /MIRROR_/);
  assert.doesNotMatch(variablesTxt({ ...BASE, MIRROR: { ENABLED: false, ROLE: "target", REMOTE: "mcsync@x" } }), /MIRROR_/);
});

test("an enabled mirror is written as MIRROR_ lines, dimensions joined by spaces", () => {
  const txt = variablesTxt({
    ...BASE,
    MIRROR: {
      ENABLED: true, ROLE: "target", REMOTE: "mcsync@survival.example", SSH_PORT: 2222,
      SOURCE_MODE: "stage", DIMS: ["minecraft/overworld", "minecraft/the_nether"], EXPORT_AT: "04:40",
      PULL_AT: "05:15", BWLIMIT_KIB: 1000, PARITY: "refuse", MIN_REGION_RATIO_PCT: 40, MAX_SNAPSHOT_GB: 80, KEEP_SNAPSHOTS: 3,
    },
  });
  for (const line of [
    'MIRROR_ENABLED="true"', 'MIRROR_ROLE="target"', 'MIRROR_REMOTE="mcsync@survival.example"', 'MIRROR_SSH_PORT="2222"',
    'MIRROR_SOURCE_MODE="stage"', 'MIRROR_DIMS="minecraft/overworld minecraft/the_nether"', 'MIRROR_EXPORT_AT="04:40"',
    'MIRROR_PULL_AT="05:15"', 'MIRROR_BWLIMIT_KIB="1000"', 'MIRROR_PARITY="refuse"', 'MIRROR_MIN_REGION_RATIO_PCT="40"',
    'MIRROR_MAX_SNAPSHOT_GB="80"', 'MIRROR_KEEP_SNAPSHOTS="3"',
  ]) {
    assert.ok(txt.includes(line), `missing ${line}`);
  }
});

test("keys that were not set are not invented", () => {
  const txt = variablesTxt({ ...BASE, MIRROR: { ENABLED: true, ROLE: "source" } });
  assert.match(txt, /MIRROR_ROLE="source"/);
  assert.doesNotMatch(txt, /MIRROR_REMOTE|MIRROR_DIMS|MIRROR_PARITY/);
});
