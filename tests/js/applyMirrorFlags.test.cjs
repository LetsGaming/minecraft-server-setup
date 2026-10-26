"use strict";

const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "..", "src", "setup", "management", "apply_mirror_flags.js");
const { applyMirrorFlags, normaliseRemote } = require(SCRIPT);
const loadVariables = require(path.join(__dirname, "..", "..", "src", "setup", "common", "loadVariables.js"));

function tmpConfig(extra = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "apply-mirror-"));
  const file = path.join(dir, "variables.json");
  fs.writeFileSync(file, JSON.stringify({ INSTANCE_NAME: "x", JAVA: { SERVER: { SEED: "" } }, ...extra }), { mode: 0o600 });
  return file;
}
const read = (f) => JSON.parse(fs.readFileSync(f, "utf8"));

test("a bare host becomes mcsync@host and the seed is stored", () => {
  const f = tmpConfig();
  applyMirrorFlags(f, { remote: "192.168.1.20", seed: "-446251370538060616" });
  const d = read(f);
  assert.deepStrictEqual(d.MIRROR, { ENABLED: true, ROLE: "target", REMOTE: "mcsync@192.168.1.20" });
  assert.strictEqual(d.JAVA.SERVER.SEED, "-446251370538060616");
});

test("mcsync@host is kept as it is", () => {
  assert.strictEqual(normaliseRemote("mcsync@survival.lan"), "mcsync@survival.lan");
});

test("an existing MIRROR block keeps its other keys, and a missing flag keeps the file's value", () => {
  const f = tmpConfig({ MIRROR: { REMOTE: "mcsync@old", PULL_AT: "06:00" }, JAVA: { SERVER: { SEED: "42" } } });
  applyMirrorFlags(f, {});
  const d = read(f);
  assert.strictEqual(d.MIRROR.PULL_AT, "06:00");
  assert.strictEqual(d.MIRROR.REMOTE, "mcsync@old");
  assert.strictEqual(d.JAVA.SERVER.SEED, "42");
  assert.strictEqual(d.MIRROR.ENABLED, true);
});

test("an invalid host or seed is rejected and the file is untouched", () => {
  const f = tmpConfig();
  const before = fs.readFileSync(f, "utf8");
  assert.throws(() => applyMirrorFlags(f, { remote: "a b;rm -rf /" }), /host name/);
  assert.throws(() => applyMirrorFlags(f, { remote: "h", seed: "1;2" }), /seed/);
  assert.strictEqual(fs.readFileSync(f, "utf8"), before);
});

test("the result passes loadVariables validation shape for MIRROR", () => {
  const f = tmpConfig();
  applyMirrorFlags(f, { remote: "h.lan", seed: "7" });
  const m = read(f).MIRROR;
  assert.match(m.REMOTE, /^mcsync@[A-Za-z0-9._:-]+$/);
  assert.strictEqual(typeof loadVariables, "function");
});

test("the command line works and exits 1 on bad input", () => {
  const f = tmpConfig();
  assert.strictEqual(spawnSync("node", [SCRIPT, f, "--remote", "h.lan", "--seed", "5"]).status, 0);
  assert.strictEqual(spawnSync("node", [SCRIPT, f, "--remote", "bad host"]).status, 1);
  assert.strictEqual(spawnSync("node", [SCRIPT, f, "--bogus", "x"]).status, 1);
});
