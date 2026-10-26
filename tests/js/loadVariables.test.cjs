// setup/common/loadVariables.js on a variables.json in a scratch tree.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SRC = path.join(__dirname, "..", "..", "src", "setup", "common", "loadVariables.js");

function load(vars) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "loadvars-"));
  try {
    const dir = path.join(root, "src", "setup", "common");
    fs.mkdirSync(dir, { recursive: true });
    fs.copyFileSync(SRC, path.join(dir, "loadVariables.js"));
    fs.writeFileSync(path.join(root, "variables.json"), JSON.stringify(vars));
    const mod = require(path.join(dir, "loadVariables.js"));
    return (mod.default ?? mod)();
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

const BASE = {
  INSTANCE_NAME: "survival",
  TARGET_DIR_NAME: "mc",
  BACKUPS: {
    COMPRESSION_LEVEL: 3,
    MAX_STORAGE_GB: 10,
    MAX_HOURLY_BACKUPS: 5,
    MAX_DAILY_BACKUPS: 5,
    MAX_WEEKLY_BACKUPS: 5,
    MAX_MONTHLY_BACKUPS: 5,
  },
  JAVA: {},
};

test("a webhook event no script sends is warned about; known ones are not", () => {
  const warnings = [];
  const realWrite = process.stderr.write;
  process.stderr.write = (chunk) => { warnings.push(String(chunk)); return true; };
  try {
    // BASE has no JAVA.SERVER, so loading ends in that error; the event check runs before it.
    assert.throws(() => load({ ...BASE, NOTIFICATIONS: { WEBHOOK_EVENTS: ["backup_failed", "storage_warning", "server_stopp"] } }), /SERVER/);
  } finally {
    process.stderr.write = realWrite;
  }
  const text = warnings.join("");
  assert.match(text, /"server_stopp"/);
  assert.doesNotMatch(text, /"backup_failed"|"storage_warning"/);
});

test("TARGET_DIR_NAME must be a plain folder name (S-001)", () => {
  for (const bad of [".", "..", "a/b", "../x", "~"]) {
    assert.throws(() => load({ ...BASE, TARGET_DIR_NAME: bad }), /TARGET_DIR_NAME/);
  }
});

test("the example's API key placeholder is refused (S-018)", () => {
  assert.throws(
    () => load({ ...BASE, API_SERVER: { ENABLED: true, API_KEY: "replace-with-a-long-random-secret" } }),
    /placeholder/,
  );
});

test("backup numbers that reach shell arithmetic must be whole numbers", () => {
  const bad = [
    ["COMPRESSION_LEVEL", 3.5],
    ["COMPRESSION_LEVEL", "3"],
    ["MAX_STORAGE_GB", 10.5],
    ["MAX_HOURLY_BACKUPS", 2.5],
    ["MAX_DAILY_BACKUPS", "5"],
    ["MAX_MONTHLY_BACKUPS", -1],
  ];
  for (const [key, value] of bad) {
    assert.throws(
      () => load({ ...BASE, BACKUPS: { ...BASE.BACKUPS, [key]: value } }),
      new RegExp(`BACKUPS\\.${key} must be`),
      `${key}=${JSON.stringify(value)}`,
    );
  }
  assert.throws(() => load({ ...BASE, BACKUPS: { ...BASE.BACKUPS, MAX_UPDATE_BACKUPS: 1.5 } }), /MAX_UPDATE_BACKUPS/);
  // Whole numbers pass this check and stop at the next missing section instead.
  assert.throws(() => load(BASE), /SERVER/);
});

test("the restart interval must divide 24 or be whole days", () => {
  for (const hours of [5, 7, 13, 25, 36, 0, 1.5, "6"]) {
    assert.throws(
      () => load({ ...BASE, RESTART_SCHEDULE: { INTERVAL_HOURS: hours } }),
      /INTERVAL_HOURS/,
      `INTERVAL_HOURS=${JSON.stringify(hours)}`,
    );
  }
  for (const hours of [1, 2, 3, 4, 6, 8, 12, 24, 48, 72]) {
    assert.throws(() => load({ ...BASE, RESTART_SCHEDULE: { INTERVAL_HOURS: hours } }), /SERVER/, `INTERVAL_HOURS=${hours}`);
  }
});

const FULL = {
  ...BASE,
  JAVA: {
    SERVER: {
      MAX_PLAYERS: 10, MOTD: "m", WHITELIST: false, SEED: "", DIFFICULTY: "normal",
      PVP: false, FLIGHT_ENABLED: true, ALLOW_CRACKED: false,
    },
    JAVA_ARGS_CONFIG: {
      minMemory: "1M", maxMemory: "1M", metaspaceLimit: "64M", garbageCollector: "zgc",
      zgc: { uncommitDelay: "1h", uncommitDelayOnIdle: "30m", heapReservePercent: 5, concurrentGCThreads: 2, softMaxHeapSize: "1M" },
    },
  },
};

function withPort(port) {
  return { ...FULL, JAVA: { ...FULL.JAVA, SERVER: { ...FULL.JAVA.SERVER, PORT: port } } };
}

test("JAVA.SERVER.PORT is optional and must be a whole number from 1 to 65535", () => {
  assert.doesNotThrow(() => load(FULL));
  for (const ok of [1, 25565, 25566, 65535]) {
    assert.doesNotThrow(() => load(withPort(ok)), `PORT=${ok}`);
  }
  for (const bad of [0, -1, 70000, 65536, 25565.5, "25565", null, true]) {
    assert.throws(
      () => load(withPort(bad)),
      /^Error: JAVA\.SERVER\.PORT must be a valid port number \(1-65535\)\.$/,
      `PORT=${JSON.stringify(bad)}`,
    );
  }
});

function withExclude(exclude) {
  const vanilla = { MODS: exclude === undefined ? {} : { EXCLUDE: exclude } };
  return { ...FULL, JAVA: { ...FULL.JAVA, SERVER: { ...FULL.JAVA.SERVER, VANILLA: vanilla } } };
}

test("JAVA.SERVER.VANILLA.MODS.EXCLUDE is optional and must be an array of slugs", () => {
  for (const ok of [undefined, [], ["a", "b"]]) {
    assert.doesNotThrow(() => load(withExclude(ok)), `EXCLUDE=${JSON.stringify(ok)}`);
  }
  for (const bad of ["a", [1], ["a", null], null, {}]) {
    assert.throws(
      () => load(withExclude(bad)),
      /^Error: JAVA\.SERVER\.VANILLA\.MODS\.EXCLUDE must be an array of mod slugs\.$/,
      `EXCLUDE=${JSON.stringify(bad)}`,
    );
  }
});

function withMirror(mirror) {
  return { ...FULL, MIRROR: mirror };
}

test("the optional MIRROR block is inert when absent, empty or switched off", () => {
  for (const ok of [undefined, {}, { ENABLED: false }, { ENABLED: false, ROLE: "target" }]) {
    assert.doesNotThrow(() => load(ok === undefined ? FULL : withMirror(ok)), `MIRROR=${JSON.stringify(ok)}`);
  }
});

test("an enabled mirror needs a role, and a target needs its source", () => {
  assert.throws(() => load(withMirror({ ENABLED: true })), /MIRROR\.ROLE is required/);
  assert.throws(() => load(withMirror({ ENABLED: true, ROLE: "target" })), /MIRROR\.REMOTE .* is required for a target/);
  assert.doesNotThrow(() => load(withMirror({ ENABLED: true, ROLE: "source" })));
  assert.doesNotThrow(() => load(withMirror({ ENABLED: true, ROLE: "target", REMOTE: "mcsync@survival.example" })));
});

test("MIRROR settings are validated", () => {
  const cases = [
    [{ ROLE: "both" }, /MIRROR\.ROLE must be/],
    [{ ENABLED: "yes" }, /MIRROR\.ENABLED must be a boolean/],
    [{ REMOTE: "root@host" }, /MIRROR\.REMOTE must look like mcsync@host/],
    [{ REMOTE: "mcsync@host;rm" }, /MIRROR\.REMOTE must look like mcsync@host/],
    [{ SSH_PORT: 70000 }, /MIRROR\.SSH_PORT/],
    [{ SOURCE_MODE: "push" }, /MIRROR\.SOURCE_MODE/],
    [{ DIMS: [] }, /MIRROR\.DIMS/],
    [{ DIMS: ["minecraft/overworld", "../etc"] }, /MIRROR\.DIMS/],
    [{ EXPORT_AT: "25:00" }, /MIRROR\.EXPORT_AT/],
    [{ PULL_AT: "5:15" }, /MIRROR\.PULL_AT/],
    [{ PARITY: "maybe" }, /MIRROR\.PARITY/],
    [{ BWLIMIT_KIB: -1 }, /MIRROR\.BWLIMIT_KIB/],
    [{ MIN_REGION_RATIO_PCT: 101 }, /MIRROR\.MIN_REGION_RATIO_PCT/],
    [{ KEEP_SNAPSHOTS: 1 }, /MIRROR\.KEEP_SNAPSHOTS must be at least 2/],
    [{ EXTRAS: ["players"] }, /MIRROR\.EXTRAS/],
    [{ EXTRAS: ["../etc"] }, /MIRROR\.EXTRAS/],
    [{ EXTRAS: "ec_player_profiles" }, /MIRROR\.EXTRAS/],
    [{ SYNC_MODS: "yes" }, /MIRROR\.SYNC_MODS must be a boolean/],
    [{ PERMISSIONS: "no" }, /MIRROR\.PERMISSIONS must be a boolean/],
  ];
  for (const [mirror, re] of cases) assert.throws(() => load(withMirror(mirror)), re, JSON.stringify(mirror));
  assert.doesNotThrow(() =>
    load(
      withMirror({
        ENABLED: true,
        ROLE: "source",
        SOURCE_MODE: "stage",
        DIMS: ["minecraft/overworld", "minecraft/the_nether"],
        EXPORT_AT: "04:40",
        BWLIMIT_KIB: 0,
        PARITY: "refuse",
        MIN_REGION_RATIO_PCT: 50,
        KEEP_SNAPSHOTS: 3,
      }),
    ),
  );
});
