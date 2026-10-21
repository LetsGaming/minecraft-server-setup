const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { makeInstance, b64, lastJson } = require("./helpers.cjs");

const API = "https://api.modrinth.com/v2";
const CDN = "https://cdn.modrinth.com/data/AANobbMI/versions/v1";

function sodiumTable(extra = {}) {
  return {
    [`${API}/project/sodium`]: { json: { id: "AANobbMI", slug: "sodium" } },
    [`${API}/project/AANobbMI/version`]: {
      json: [
        {
          id: "ver1",
          name: "Sodium 1.0",
          date_published: "2026-01-01T00:00:00Z",
          game_versions: ["1.21.4"],
          loaders: ["fabric"],
          dependencies: [],
          files: [{ primary: true, url: `${CDN}/sodium-1.0.jar`, filename: "sodium-1.0.jar" }],
        },
      ],
    },
    [`${CDN}/sodium-1.0.jar`]: { bodyBase64: b64("JARBYTES"), headers: {} },
    ...extra,
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
  "installs a mod and registers it, reporting ok in --json mode",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(sodiumTable());
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(res.code, 0, res.stderr);
    assert.deepEqual(lastJson(res.stdout), { ok: true, slug: "sodium" });
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium-1.0.jar"), "utf8"), "JARBYTES");
    assert.deepEqual(inst.readManifest().mods.sodium, {
      versionId: "ver1",
      filename: "sodium-1.0.jar",
    });
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar.tmp")), false);
  }),
);

test(
  "in --json mode stdout carries exactly one JSON object",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(sodiumTable());
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(res.stdout.trim().split("\n").length, 1);
  }),
);

test(
  "human mode prints progress and Done",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(sodiumTable());
    const res = inst.run("add-mod.js", ["sodium"]);
    assert.equal(res.code, 0, res.stderr);
    assert.match(res.stdout, /Registered "sodium"/);
    assert.match(res.stdout, /Done\./);
  }),
);

test(
  "an unknown project is a handled not-found failure",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub({ [`${API}/project/nope`]: { status: 404, json: {} } });
    const res = inst.run("add-mod.js", ["nope", "--json"]);
    assert.equal(res.code, 1);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "not-found");
  }),
);

test(
  "an already registered mod is a successful no-op",
  withInstance((inst) => {
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver0", filename: "sodium-0.9.jar" } },
    });
    inst.stub(sodiumTable());
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(res.code, 0);
    assert.deepEqual(lastJson(res.stdout), { ok: true, slug: "sodium" });
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")), false);
  }),
);

test(
  "no compatible version is classified",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(sodiumTable({ [`${API}/project/AANobbMI/version`]: { json: [] } }));
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(lastJson(res.stdout).code, "no-compatible-version");
  }),
);

test(
  "a missing manifest is classified as a manifest failure",
  withInstance((inst) => {
    inst.stub(sodiumTable());
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(res.code, 1);
    assert.equal(lastJson(res.stdout).code, "manifest");
  }),
);

test(
  "installs required dependencies after the mod itself",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    const table = sodiumTable();
    table[`${API}/project/AANobbMI/version`].json[0].dependencies = [
      { dependency_type: "required", project_id: "P7dR8mSH" },
    ];
    table[`${API}/project/P7dR8mSH`] = { json: { id: "P7dR8mSH", slug: "fabric-api" } };
    table[`${API}/project/P7dR8mSH/version`] = {
      json: [
        {
          id: "fapi1",
          name: "Fabric API",
          date_published: "2026-01-01T00:00:00Z",
          game_versions: ["1.21.4"],
          loaders: ["fabric"],
          dependencies: [],
          files: [{ primary: true, url: `${CDN}/fabric-api-1.jar` }],
        },
      ],
    };
    table[`${CDN}/fabric-api-1.jar`] = { bodyBase64: b64("DEP"), headers: {} };
    inst.stub(table);
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(res.code, 0, res.stderr);
    assert.ok(fs.existsSync(path.join(inst.mods, "fabric-api-1.jar")));
    assert.equal(inst.readManifest().mods["fabric-api"].versionId, "fapi1");
  }),
);

test(
  "re-adding a registered mod installs a required dependency an earlier run missed (S-023)",
  withInstance((inst) => {
    const FAPI_CDN = "https://cdn.modrinth.com/data/P7dR8mSH/versions/f1";
    inst.writeManifest({
      gameVersion: "1.21.4",
      modLoader: "fabric",
      mods: { sodium: { versionId: "ver1", filename: "sodium-1.0.jar" } },
    });
    inst.stub({
      [`${API}/project/sodium`]: { json: { id: "AANobbMI", slug: "sodium" } },
      [`${API}/version/ver1`]: {
        json: {
          id: "ver1",
          dependencies: [{ project_id: "P7dR8mSH", dependency_type: "required" }],
          files: [{ primary: true, url: `${CDN}/sodium-1.0.jar` }],
        },
      },
      [`${API}/project/P7dR8mSH`]: { json: { id: "P7dR8mSH", slug: "fabric-api" } },
      [`${API}/project/P7dR8mSH/version`]: {
        json: [
          {
            id: "f1",
            date_published: "2026-01-01T00:00:00Z",
            game_versions: ["1.21.4"],
            loaders: ["fabric"],
            dependencies: [],
            files: [{ primary: true, url: `${FAPI_CDN}/fabric-api-1.0.jar` }],
          },
        ],
      },
      [`${FAPI_CDN}/fabric-api-1.0.jar`]: { bodyBase64: b64("FAPI"), headers: {} },
    });
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(lastJson(res.stdout).ok, true, res.stderr);
    assert.deepEqual(inst.readManifest().mods["fabric-api"], { versionId: "f1", filename: "fabric-api-1.0.jar" });
    assert.equal(fs.readFileSync(path.join(inst.mods, "fabric-api-1.0.jar"), "utf8"), "FAPI");
  }),
);

function xaeroTable(slug) {
  const cdn = `https://cdn.modrinth.com/data/AANobbMI/versions/${slug}`;
  return {
    [`${API}/project/${slug}`]: { json: { id: "AANobbMI", slug } },
    [`${API}/project/AANobbMI/version`]: {
      json: [
        {
          id: "ver1",
          name: `${slug} 1.0`,
          date_published: "2026-01-01T00:00:00Z",
          game_versions: ["1.21.4"],
          loaders: ["fabric"],
          dependencies: [],
          files: [{ primary: true, url: `${cdn}/${slug}-1.0.jar`, filename: `${slug}-1.0.jar` }],
        },
      ],
    },
    [`${cdn}/${slug}-1.0.jar`]: { bodyBase64: b64("JARBYTES"), headers: {} },
  };
}

function installXaeroStub(inst, exitCode = 0) {
  const dir = path.join(inst.scripts, "misc");
  fs.mkdirSync(dir, { recursive: true });
  const log = path.join(inst.root, "xaero.log");
  fs.writeFileSync(
    path.join(dir, "xaero_config.sh"),
    `#!/bin/bash\necho "$@" >> "${log.split(path.sep).join("/")}"\necho "stub says no" >&2\nexit ${exitCode}\n`,
  );
  return log;
}

test(
  "runs_xaero_apply_after_adding_a_xaero_mod",
  withInstance((inst) => {
    const log = installXaeroStub(inst);
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(xaeroTable("xaeros-minimap"));
    const res = inst.run("add-mod.js", ["xaeros-minimap", "--json"]);
    assert.equal(res.code, 0, res.stderr);
    assert.deepEqual(lastJson(res.stdout), { ok: true, slug: "xaeros-minimap" });
    const calls = fs.readFileSync(log, "utf8").trim().split("\n");
    assert.equal(calls.length, 1);
    assert.match(calls[0], /^apply /);
  }),
);

test(
  "does_not_run_for_other_mods",
  withInstance((inst) => {
    const log = installXaeroStub(inst);
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(sodiumTable());
    const res = inst.run("add-mod.js", ["sodium", "--json"]);
    assert.equal(res.code, 0, res.stderr);
    assert.equal(fs.existsSync(log), false);
  }),
);

test(
  "failure_is_logged_but_does_not_change_exit_code_or_json",
  withInstance((inst) => {
    installXaeroStub(inst, 1);
    inst.writeManifest({ gameVersion: "1.21.4", modLoader: "fabric", mods: {} });
    inst.stub(xaeroTable("xaeros-minimap"));
    const res = inst.run("add-mod.js", ["xaeros-minimap", "--json"]);
    assert.equal(res.code, 0, res.stderr);
    assert.equal(res.stdout.trim().split("\n").length, 1);
    assert.deepEqual(lastJson(res.stdout), { ok: true, slug: "xaeros-minimap" });
    assert.match(res.stderr, /Could not apply the Xaero config: stub says no/);
  }),
);
