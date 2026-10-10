const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const lib = path.resolve(__dirname, "..", "..", "src", "scripts", "update", "lib");
const { parseVariables, loadVariables } = require(path.join(lib, "variables.js"));
const { escapeRegex, detectInstalledJars } = require(path.join(lib, "jars.js"));

test("parseVariables strips quotes, ignores junk lines and handles CRLF", () => {
  const vars = parseVariables('A="one"\r\nB=\'two\'\r\n# comment\r\nC=three words\r\nnot a pair\r\n');
  assert.deepEqual(vars, { A: "one", B: "two", C: "three words" });
});

test("loadVariables throws on a missing file unless optional", () => {
  const missing = path.join(os.tmpdir(), "mcsetup-no-such-variables.txt");
  assert.throws(() => loadVariables(missing));
  assert.deepEqual(loadVariables(missing, { optional: true }), {});
});

test("escapeRegex neutralises every metacharacter", () => {
  const nasty = "a.b*c+d?e^f$g{h}i(j)k|l[m]n\\o";
  assert.ok(new RegExp(`^${escapeRegex(nasty)}$`).test(nasty));
});

test("detectInstalledJars matches whole slug tokens only and skips symlinks", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-jars-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const f of ["sodium-1.0.jar", "sodium-extra-1.0.jar", "my-sodium.jar", "other.jar", "sodium-1.0.jar.tmp"]) {
    fs.writeFileSync(path.join(dir, f), "x");
  }
  const found = detectInstalledJars(dir, "sodium").map((j) => j.file).sort();
  assert.deepEqual(found, ["sodium-1.0.jar", "sodium-extra-1.0.jar"]);
  assert.deepEqual(detectInstalledJars(dir, "sodium", "sodium-1.0.jar").map((j) => j.file).sort(), [
    "sodium-extra-1.0.jar",
  ]);
  assert.deepEqual(detectInstalledJars(path.join(dir, "absent"), "sodium"), []);
});

test("createJsonMode silences human channels and emits one line", () => {
  const script = `
    const { createJsonMode } = require(${JSON.stringify(path.join(lib, "json-mode.js"))});
    const m = createJsonMode(true, { captureErrors: true, silenceStdoutWrite: true });
    console.log("hidden");
    process.stdout.write("also hidden");
    console.error("boom");
    m.emit({ ok: false, error: m.lastError() });
  `;
  const res = spawnSync(process.execPath, ["-e", script], { encoding: "utf8" });
  assert.equal(res.stdout, '{"ok":false,"error":"boom"}\n');
});

test("createJsonMode leaves the console alone when disabled", () => {
  const script = `
    const { createJsonMode } = require(${JSON.stringify(path.join(lib, "json-mode.js"))});
    createJsonMode(false);
    console.log("visible");
  `;
  const res = spawnSync(process.execPath, ["-e", script], { encoding: "utf8" });
  assert.equal(res.stdout, "visible\n");
});
