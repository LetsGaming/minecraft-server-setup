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
