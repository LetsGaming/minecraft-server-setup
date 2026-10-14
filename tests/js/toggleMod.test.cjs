const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { makeInstance, lastJson } = require("./helpers.cjs");

function withInstance(fn) {
  return async () => {
    const inst = makeInstance();
    try {
      await fn(inst);
    } finally {
      inst.cleanup();
    }
  };
}

test(
  "disable moves the jar into mods/disabled and enable moves it back",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "x");
    inst.writeManifest({ mods: { sodium: { versionId: "v1", filename: "sodium-1.0.jar" } } });

    const off = inst.run("toggle-mod.js", ["sodium", "--disable", "--json"]);
    assert.equal(lastJson(off.stdout).ok, true, off.stderr);
    assert.ok(fs.existsSync(path.join(inst.mods, "disabled", "sodium-1.0.jar")));
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), false);

    const on = inst.run("toggle-mod.js", ["sodium", "--enable", "--json"]);
    assert.equal(lastJson(on.stdout).ok, true, on.stderr);
    assert.ok(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")));
  }),
);

test(
  "toggling an unknown mod is a handled failure",
  withInstance((inst) => {
    inst.writeManifest({ mods: {} });
    const res = inst.run("toggle-mod.js", ["ghost", "--disable", "--json"]);
    assert.equal(res.code, 1);
    assert.equal(lastJson(res.stdout).ok, false);
  }),
);

test(
  "a slug with Modrinth's other characters (sit!) is disabled and enabled like any other",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sit-fabric-1.4.jar"), "x");
    inst.writeManifest({ mods: { "sit!": { versionId: "s1", filename: "sit-fabric-1.4.jar" } } });

    const off = inst.run("toggle-mod.js", ["sit!", "--disable", "--json"]);
    assert.equal(lastJson(off.stdout).ok, true, off.stderr);
    assert.ok(fs.existsSync(path.join(inst.mods, "disabled", "sit-fabric-1.4.jar")));

    const on = inst.run("toggle-mod.js", ["sit!", "--enable", "--json"]);
    assert.equal(lastJson(on.stdout).ok, true, on.stderr);
    assert.ok(fs.existsSync(path.join(inst.mods, "sit-fabric-1.4.jar")));
  }),
);
