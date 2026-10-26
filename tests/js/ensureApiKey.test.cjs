"use strict";

const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "..", "src", "setup", "management", "ensure_api_key.js");
const { ensureApiKey } = require(SCRIPT);

function tmpConfig(api) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ensure-api-key-"));
  const file = path.join(dir, "variables.json");
  fs.writeFileSync(file, JSON.stringify({ INSTANCE_NAME: "x", API_SERVER: api }), { mode: 0o600 });
  return file;
}

const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

test("an empty key is replaced by a 64 character hex key and the wrapper is enabled", () => {
  const file = tmpConfig({ ENABLED: false, PORT: 3030, API_KEY: "" });
  assert.strictEqual(ensureApiKey(file), true);
  const api = read(file).API_SERVER;
  assert.match(api.API_KEY, /^[0-9a-f]{64}$/);
  assert.strictEqual(api.ENABLED, true);
  assert.strictEqual(api.PORT, 3030, "other settings are kept");
});

test("the example placeholder key is replaced even though it is long enough", () => {
  const file = tmpConfig({ ENABLED: true, API_KEY: "replace-with-a-long-random-secret" });
  assert.strictEqual(ensureApiKey(file), true);
  assert.match(read(file).API_SERVER.API_KEY, /^[0-9a-f]{64}$/);
});

test("a key that is too short is replaced", () => {
  const file = tmpConfig({ ENABLED: true, API_KEY: "short" });
  assert.strictEqual(ensureApiKey(file), true);
  assert.match(read(file).API_SERVER.API_KEY, /^[0-9a-f]{64}$/);
});

test("a long enough key is kept and the file is left alone", () => {
  const key = "k".repeat(40);
  const file = tmpConfig({ ENABLED: true, API_KEY: key });
  const before = fs.readFileSync(file, "utf8");
  assert.strictEqual(ensureApiKey(file), false);
  assert.strictEqual(fs.readFileSync(file, "utf8"), before);
});

test("a long key with the wrapper disabled keeps the key and enables it", () => {
  const key = "k".repeat(40);
  const file = tmpConfig({ ENABLED: false, API_KEY: key });
  assert.strictEqual(ensureApiKey(file), true);
  const api = read(file).API_SERVER;
  assert.strictEqual(api.API_KEY, key);
  assert.strictEqual(api.ENABLED, true);
});

test("a missing API_SERVER block is created", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ensure-api-key-"));
  const file = path.join(dir, "variables.json");
  fs.writeFileSync(file, JSON.stringify({ INSTANCE_NAME: "x" }));
  ensureApiKey(file);
  assert.match(read(file).API_SERVER.API_KEY, /^[0-9a-f]{64}$/);
});

test("the file mode is preserved and the command never prints the key", { skip: process.platform === "win32" }, () => {
  const file = tmpConfig({ ENABLED: false, API_KEY: "" });
  const res = spawnSync(process.execPath, [SCRIPT, file], { encoding: "utf8" });
  assert.strictEqual(res.status, 0);
  const key = read(file).API_SERVER.API_KEY;
  assert.ok(!res.stdout.includes(key) && !res.stderr.includes(key), "the key is not in the output");
  assert.strictEqual(fs.statSync(file).mode & 0o777, 0o600);
});

test("an unreadable file exits 1 with a message", () => {
  const res = spawnSync(process.execPath, [SCRIPT, path.join(os.tmpdir(), "does-not-exist.json")], { encoding: "utf8" });
  assert.strictEqual(res.status, 1);
  assert.match(res.stderr, /Could not prepare the API key/);
});
