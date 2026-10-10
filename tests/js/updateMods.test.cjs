const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { makeInstance, b64, lastJson } = require("./helpers.cjs");

const API = "https://api.modrinth.com/v2";
const CDN = "https://cdn.modrinth.com/data/AANobbMI/versions/v2";

function updateTable() {
  return {
    [`${API}/project/sodium`]: { json: { id: "AANobbMI", slug: "sodium" } },
    [`${API}/project/AANobbMI/version`]: {
      json: [
        {
          id: "ver2",
          name: "Sodium 2.0",
          date_published: "2026-02-01T00:00:00Z",
          game_versions: ["1.21.4"],
          loaders: ["fabric"],
          files: [{ primary: true, url: `${CDN}/sodium-2.0.jar` }],
        },
      ],
    },
    [`${CDN}/sodium-2.0.jar`]: { bodyBase64: b64("NEWJAR"), headers: {} },
  };
}

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
  "replaces the old jar with the new build and updates the manifest",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "OLD");
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver1", filename: "sodium-1.0.jar" } },
    });
    inst.stub(updateTable());
    const res = inst.run("update-mods.js", ["--json"]);
    assert.equal(res.code, 0, res.stderr);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, true);
    assert.deepEqual(out.updated, [
      { slug: "sodium", toVersionId: "ver2", filename: "sodium-2.0.jar" },
    ]);
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), false);
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium-2.0.jar"), "utf8"), "NEWJAR");
    assert.equal(inst.readManifest().mods.sodium.versionId, "ver2");
  }),
);

test(
  "keeps an updated disabled mod in mods/disabled",
  withInstance((inst) => {
    fs.mkdirSync(path.join(inst.mods, "disabled"));
    fs.writeFileSync(path.join(inst.mods, "disabled", "sodium-1.0.jar"), "OLD");
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver1", filename: "sodium-1.0.jar" } },
    });
    inst.stub(updateTable());
    inst.run("update-mods.js", ["--json"]);
    assert.ok(fs.existsSync(path.join(inst.mods, "disabled", "sodium-2.0.jar")));
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-2.0.jar")), false);
  }),
);

test(
  "a mod already at the latest version is reported up to date",
  withInstance((inst) => {
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver2", filename: "sodium-2.0.jar" } },
    });
    inst.stub(updateTable());
    const out = lastJson(inst.run("update-mods.js", ["--json"]).stdout);
    assert.deepEqual(out.upToDate, ["sodium"]);
    assert.deepEqual(out.updated, []);
  }),
);

test(
  "a failed download is reported per mod and leaves no temp file",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "OLD");
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver1", filename: "sodium-1.0.jar" } },
    });
    const table = updateTable();
    delete table[`${CDN}/sodium-2.0.jar`];
    inst.stub(table);
    const out = lastJson(inst.run("update-mods.js", ["--json"]).stdout);
    assert.equal(out.ok, true);
    assert.equal(out.failed.length, 1);
    assert.equal(out.failed[0].slug, "sodium");
    assert.ok(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")));
    assert.deepEqual(fs.readdirSync(inst.mods).filter((f) => f.endsWith(".tmp")), []);
  }),
);

test(
  "update-mod.js scopes the run to one slug and reports an unknown one",
  withInstance((inst) => {
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver2", filename: "sodium-2.0.jar" } },
    });
    inst.stub(updateTable());
    const res = inst.run("update-mod.js", ["ghost", "--json"]);
    assert.equal(res.code, 1);
    assert.deepEqual(lastJson(res.stdout), {
      ok: false,
      slug: "ghost",
      error: "Mod is not installed.",
      code: "update-failed",
    });
  }),
);

test(
  "--migrate locks legacy string entries to the jar found on disk",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "lithium-fabric-0.1.jar"), "x");
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: { lithium: "legacyid" } });
    const out = lastJson(inst.run("update-mods.js", ["--migrate", "--json"]).stdout);
    assert.deepEqual(out, { ok: true, migrated: true });
    assert.deepEqual(inst.readManifest().mods.lithium, {
      versionId: "legacyid",
      filename: "lithium-fabric-0.1.jar",
    });
  }),
);
