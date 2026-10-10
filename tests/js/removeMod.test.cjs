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
  "removes the recorded jar and the manifest entry",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "x");
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "v1", filename: "sodium-1.0.jar" } },
    });
    const res = inst.run("remove-mod.js", ["sodium", "--json"]);
    assert.equal(res.code, 0, res.stderr);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, true);
    assert.equal(out.slug, "sodium");
    assert.equal(out.removedFile, "sodium-1.0.jar");
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), false);
    assert.deepEqual(inst.readManifest().mods, {});
  }),
);

test(
  "also removes a disabled jar",
  withInstance((inst) => {
    fs.mkdirSync(path.join(inst.mods, "disabled"));
    fs.writeFileSync(path.join(inst.mods, "disabled", "lithium-1.jar"), "x");
    inst.writeManifest({
      mods: { lithium: { versionId: "v1", filename: "lithium-1.jar" } },
    });
    const res = inst.run("remove-mod.js", ["lithium", "--json"]);
    assert.equal(lastJson(res.stdout).removedFile, "lithium-1.jar");
    assert.equal(fs.existsSync(path.join(inst.mods, "disabled", "lithium-1.jar")), false);
  }),
);

test(
  "a legacy entry without a filename falls back to a slug scan",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "ferrite-core-6.0.jar"), "x");
    fs.writeFileSync(path.join(inst.mods, "other-1.jar"), "x");
    inst.writeManifest({ mods: { "ferrite-core": "legacy-version-id" } });
    const res = inst.run("remove-mod.js", ["ferrite-core", "--json"]);
    assert.equal(lastJson(res.stdout).removedFile, "ferrite-core-6.0.jar");
    assert.ok(fs.existsSync(path.join(inst.mods, "other-1.jar")));
  }),
);

test(
  "an unknown slug is a handled not-installed failure",
  withInstance((inst) => {
    inst.writeManifest({ mods: {} });
    const res = inst.run("remove-mod.js", ["ghost", "--json"]);
    assert.equal(res.code, 1);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "not-installed");
  }),
);

test(
  "a missing manifest is a manifest failure",
  withInstance((inst) => {
    const res = inst.run("remove-mod.js", ["x", "--json"]);
    assert.equal(lastJson(res.stdout).code, "manifest");
  }),
);

test(
  "human mode reports Done",
  withInstance((inst) => {
    inst.writeManifest({ mods: { a: { versionId: "v", filename: "a.jar" } } });
    const res = inst.run("remove-mod.js", ["a"]);
    assert.match(res.stdout, /Done\./);
  }),
);
