const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");

const { parseArgs } = require(path.resolve(__dirname, "..", "..", "src", "scripts", "update", "lib", "args.js"));

function withArgv(argv, fn) {
  const saved = process.argv;
  process.argv = ["node", "script.js", ...argv];
  try {
    return fn();
  } finally {
    process.argv = saved;
  }
}

test("positional values bind by index and flags override them", () => {
  withArgv(["sodium", "1.21", "--modLoader=fabric", "--mcVersion=1.20"], () => {
    const a = parseArgs({ positional: ["slug", "mcVersion"], flags: { modLoader: null, mcVersion: null } });
    assert.equal(a.get("slug"), "sodium");
    assert.equal(a.get("mcVersion"), "1.20");
    assert.equal(a.get("modLoader"), "fabric");
  });
});

test("boolean flags and defaults", () => {
  withArgv(["--json"], () => {
    const a = parseArgs({ flags: { mcVersion: "latest" }, boolFlags: ["json"] });
    assert.equal(a.bool("json"), true);
    assert.equal(a.bool("migrate"), false);
    assert.equal(a.get("mcVersion"), "latest");
  });
});

test("a value containing = keeps everything after the first =", () => {
  withArgv(["--versionId=a=b"], () => {
    assert.equal(parseArgs({ flags: { versionId: null } }).get("versionId"), "a=b");
  });
});

test("extra positionals are exposed", () => {
  withArgv(["a", "b", "c"], () => {
    assert.deepEqual(parseArgs({ positional: ["first"] }).extra, ["b", "c"]);
  });
});

test("a bare -- ends option parsing", () => {
  withArgv(["--json", "--", "--json", "--help", "-x"], () => {
    const a = parseArgs({ boolFlags: ["json", "help"], positional: ["slug"] });
    assert.equal(a.bool("json"), true);
    assert.equal(a.bool("help"), false);
    assert.equal(a.get("slug"), "--json");
    assert.deepEqual(a.extra, ["--help", "-x"]);
  });
});

test("flags before -- still apply when a positional follows", () => {
  withArgv(["--mcVersion=1.21", "--", "sodium"], () => {
    const a = parseArgs({ positional: ["slug"], flags: { mcVersion: null } });
    assert.equal(a.get("slug"), "sodium");
    assert.equal(a.get("mcVersion"), "1.21");
  });
});
