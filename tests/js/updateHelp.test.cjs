"use strict";

const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const UPDATE_DIR = path.join(__dirname, "..", "..", "src", "scripts", "update");
const SCRIPTS = [
  "add-mod.js",
  "remove-mod.js",
  "toggle-mod.js",
  "update-mod.js",
  "update-mods.js",
  "update-server.js",
  "upgrade-server.js",
  "check-updates.js",
];

// A help request must never start an update (update-server.js used to ignore
// --help and run for real). The scripts run in an empty folder with no
// variables.txt, so anything that gets past the help check fails loudly.
for (const script of SCRIPTS) {
  for (const flag of ["--help", "-h"]) {
    test(`${script} ${flag} prints the usage and does nothing else`, () => {
      const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "update-help-"));
      const res = spawnSync(process.execPath, [path.join(UPDATE_DIR, script), flag], {
        cwd,
        encoding: "utf8",
        timeout: 20000,
      });
      assert.strictEqual(res.status, 0, `exit status (stderr: ${res.stderr})`);
      assert.match(res.stdout, /^Usage: node /, "usage is printed on stdout");
      assert.ok(res.stdout.includes(script), "the usage names the script");
      assert.deepStrictEqual(fs.readdirSync(cwd), [], "nothing is created in the working folder");
    });
  }
}
