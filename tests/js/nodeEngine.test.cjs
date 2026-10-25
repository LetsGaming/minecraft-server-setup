"use strict";

const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { engineWarning } = require("../../src/setup/common/nodeEngine");

function pkg(engines) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "node-engine-"));
  const file = path.join(dir, "package.json");
  fs.writeFileSync(file, JSON.stringify(engines === undefined ? {} : { engines }));
  return file;
}

test("a Node that is too old gets a warning naming both versions", () => {
  const msg = engineWarning(pkg({ node: ">=22" }), "v20.19.2");
  assert.match(msg, /Node 20\.19\.2 is older than the >=22/);
});

test("a Node that meets the range gets no warning", () => {
  assert.strictEqual(engineWarning(pkg({ node: ">=22" }), "v22.4.0"), null);
  assert.strictEqual(engineWarning(pkg({ node: ">=18" }), "v20.19.2"), null);
});

test("no engines, a missing file or a broken range give no warning", () => {
  assert.strictEqual(engineWarning(pkg(undefined), "v18.0.0"), null);
  assert.strictEqual(engineWarning(path.join(os.tmpdir(), "nope", "package.json"), "v18.0.0"), null);
  assert.strictEqual(engineWarning(pkg({ node: "not a range" }), "v18.0.0"), null);
});
