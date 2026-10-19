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
    assert.deepEqual(Object.keys(out).sort(), ["ok", "removedFile", "slug"]);
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

// S-008: removing a mod never takes another mod whose name shares its prefix.
test(
  "keeps a sibling whose name starts with the removed mod's slug",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "x");
    fs.writeFileSync(path.join(inst.mods, "sodium-extra-fabric-0.5.jar"), "x");
    inst.writeManifest({
      mods: {
        sodium: { versionId: "v1", filename: "sodium-1.0.jar" },
        "sodium-extra": { versionId: "v2", filename: "sodium-extra-fabric-0.5.jar" },
      },
    });
    const res = inst.run("remove-mod.js", ["sodium", "--json"]);
    assert.equal(lastJson(res.stdout).ok, true, res.stderr);
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), false);
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-extra-fabric-0.5.jar")), true);
    assert.deepEqual(Object.keys(inst.readManifest().mods), ["sodium-extra"]);
  }),
);

test(
  "refuses to guess when a legacy slug scan matches several jars",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "carpet-1.4.jar"), "x");
    fs.writeFileSync(path.join(inst.mods, "carpet-extra-1.4.jar"), "x");
    inst.writeManifest({ mods: { carpet: "legacy-version-id" } });
    const res = inst.run("remove-mod.js", ["carpet", "--json"]);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "ambiguous");
    assert.equal(fs.existsSync(path.join(inst.mods, "carpet-1.4.jar")), true);
    assert.equal(fs.existsSync(path.join(inst.mods, "carpet-extra-1.4.jar")), true);
  }),
);

test(
  "a corrupt manifest is an error, not an empty one (S-024)",
  withInstance((inst) => {
    fs.writeFileSync(inst.manifestPath ?? path.join(inst.scripts, "common", "downloaded_versions.json"), "{ not json");
    const res = inst.run("remove-mod.js", ["sodium", "--json"]);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "manifest");
  }),
);

test(
  "waits for, then reports, an operation that holds the instance lock (S-024)",
  withInstance((inst) => {
    const { spawnSync, spawn } = require("child_process");
    if (spawnSync("sh", ["-c", "command -v flock"]).status !== 0) return; // no flock here
    const lockDir = path.join(inst.root ?? path.dirname(inst.scripts), "locks");
    fs.mkdirSync(lockDir, { recursive: true });
    const lock = path.join(lockDir, "operation_inst.lock");
    fs.writeFileSync(`${lock}.kind`, "upgrade\n");
    const holder = spawn("flock", [lock, "sleep", "90"], { stdio: "ignore" });
    try {
      // Give flock a moment to take the lock.
      spawnSync("sleep", ["0.3"]);
      fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "x");
      inst.writeManifest({ mods: { sodium: { versionId: "v1", filename: "sodium-1.0.jar" } } });
      const res = inst.run("remove-mod.js", ["sodium", "--json"], {
        INSTANCE_LOCK_DIR: lockDir,
        MC_OPERATION_LOCK_HELD: "",
        MC_TEST_LOCK_WAIT: "1",
      });
      const out = lastJson(res.stdout);
      assert.equal(out.ok, false);
      assert.equal(out.code, "busy");
      assert.match(out.error, /upgrade/);
      assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), true);
    } finally {
      holder.kill();
    }
  }),
);

// ── the mod scripts take the operation lock even without flock(1) ──

function withManifestMod(inst) {
  fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "x");
  inst.writeManifest({ mods: { sodium: { versionId: "v1", filename: "sodium-1.0.jar" } } });
}

const NO_FLOCK = (lockDir) => ({ INSTANCE_LOCK_DIR: lockDir, MC_OPERATION_LOCK_HELD: "", MC_TEST_NO_FLOCK: "1", MC_TEST_LOCK_WAIT: "1" });

test(
  "without flock a live holder's mkdir lock keeps the script out",
  withInstance((inst) => {
    withManifestMod(inst);
    const lockDir = path.join(inst.root, "locks");
    const held = path.join(lockDir, "operation_inst.lock.d");
    fs.mkdirSync(held, { recursive: true });
    fs.writeFileSync(path.join(held, "pid"), `${process.pid}\n`);
    fs.writeFileSync(path.join(lockDir, "operation_inst.lock.kind"), "restore\n");
    const res = inst.run("remove-mod.js", ["sodium", "--json"], NO_FLOCK(lockDir));
    const out = lastJson(res.stdout);
    assert.equal(res.code, 75);
    assert.equal(out.ok, false);
    assert.equal(out.code, "busy");
    assert.match(out.error, /restore/);
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), true, "nothing was removed");
    assert.equal(fs.existsSync(held), true, "the holder's lock is left alone");
  }),
);

test(
  "without flock the lock of a dead holder is taken over, and released afterwards",
  withInstance((inst) => {
    withManifestMod(inst);
    const lockDir = path.join(inst.root, "locks");
    const held = path.join(lockDir, "operation_inst.lock.d");
    fs.mkdirSync(held, { recursive: true });
    fs.writeFileSync(path.join(held, "pid"), "999999\n");
    const res = inst.run("remove-mod.js", ["sodium", "--json"], NO_FLOCK(lockDir));
    assert.equal(res.code, 0, res.stderr);
    assert.equal(lastJson(res.stdout).ok, true);
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), false);
    assert.equal(fs.existsSync(held), false, "the lock folder is gone after the run");
  }),
);

test(
  "without flock a free lock is taken for the run and records who holds it",
  withInstance((inst) => {
    withManifestMod(inst);
    const lockDir = path.join(inst.root, "locks");
    const res = inst.run("remove-mod.js", ["sodium", "--json"], NO_FLOCK(lockDir));
    assert.equal(res.code, 0, res.stderr);
    assert.equal(fs.readFileSync(path.join(lockDir, "operation_inst.lock.kind"), "utf8").trim(), "mods");
    assert.equal(fs.existsSync(path.join(lockDir, "operation_inst.lock.d")), false);
  }),
);

test(
  "a jar that cannot be deleted keeps its manifest entry",
  withInstance((inst) => {
    // A directory named like the jar: unlink fails on every platform.
    fs.mkdirSync(path.join(inst.mods, "sodium-1.0.jar"));
    inst.writeManifest({ mods: { sodium: { versionId: "v1", filename: "sodium-1.0.jar" } } });
    const res = inst.run("remove-mod.js", ["sodium", "--json"], { MC_OPERATION_LOCK_HELD: "1" });
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "remove-failed");
    assert.ok(inst.readManifest().mods.sodium, "the mod is still registered");
  }),
);
