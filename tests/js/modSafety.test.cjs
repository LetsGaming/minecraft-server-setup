// Mod installs and updates: which build is chosen, what counts as a failure, what
// is trusted on disk, and that new dependencies come along.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { makeInstance, b64, sha, lastJson } = require("./helpers.cjs");

const API = "https://api.modrinth.com/v2";
const HELD = { MC_OPERATION_LOCK_HELD: "1" };

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

const version = (id, extra = {}) => ({
  id,
  name: `Build ${id}`,
  date_published: "2026-01-01T00:00:00Z",
  version_type: "release",
  game_versions: ["1.21.5"],
  loaders: ["fabric"],
  dependencies: [],
  files: [{ primary: true, url: `https://cdn/${id}.jar`, hashes: { sha512: "ab" } }],
  ...extra,
});

function seed(inst, versions, installedId = "old") {
  inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: { sodium: { versionId: installedId } } });
  inst.stub({
    [`${API}/project/sodium`]: { json: { id: "sod", slug: "sodium" } },
    [`${API}/project/sod/version`]: { json: versions },
  });
}

const check = (inst) => JSON.parse(inst.run("check-updates.js", ["1.21.5", "--json"], HELD).stdout).results[0];

// ── which build ──

test(
  "a release is preferred over a newer beta",
  withInstance((inst) => {
    seed(inst, [
      version("beta-new", { version_type: "beta", date_published: "2026-03-01T00:00:00Z" }),
      version("rel-old", { date_published: "2026-01-01T00:00:00Z" }),
    ]);
    assert.equal(check(inst).latestVersionId, "rel-old");
  }),
);

test(
  "a beta is used only when the mod has no release, and an alpha only after that",
  withInstance((inst) => {
    seed(inst, [
      version("alpha", { version_type: "alpha", date_published: "2026-04-01T00:00:00Z" }),
      version("beta", { version_type: "beta", date_published: "2026-02-01T00:00:00Z" }),
    ]);
    assert.equal(check(inst).latestVersionId, "beta");
    seed(inst, [version("alpha", { version_type: "alpha" })]);
    assert.equal(check(inst).latestVersionId, "alpha");
  }),
);

test(
  "an installed beta that is newer than the last release is not an update to move away from",
  withInstance((inst) => {
    seed(
      inst,
      [
        version("beta-now", { version_type: "beta", date_published: "2026-03-01T00:00:00Z" }),
        version("rel-old", { date_published: "2026-01-01T00:00:00Z" }),
      ],
      "beta-now",
    );
    assert.equal(check(inst).status, "up_to_date");
  }),
);

test(
  "an update names its project and the dependencies it requires",
  withInstance((inst) => {
    seed(inst, [
      version("new", {
        dependencies: [
          { project_id: "DEP", version_id: null, dependency_type: "required" },
          { project_id: "OPT", dependency_type: "optional" },
        ],
      }),
    ]);
    const r = check(inst);
    assert.equal(r.status, "update_available");
    assert.equal(r.projectId, "sod");
    assert.deepEqual(r.requiredDependencies, [{ projectId: "DEP", versionId: null }]);
  }),
);

test(
  "a slug is encoded into the API path and an API error is reported as text",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: { "odd/slug?x": { versionId: "v1" } } });
    inst.stub({ [`${API}/project/${encodeURIComponent("odd/slug?x")}`]: { status: 500, json: { description: "boom" } } });
    const r = check(inst);
    assert.equal(r.status, "error");
    assert.equal(typeof r.error, "string");
    assert.ok(inst.requests().every((u) => !u.includes("odd/slug")), "the slash never reaches the path unencoded");
  }),
);

// ── what counts as a failed update ──

test(
  "a mod that could not be checked is a failure, not 'no update available'",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: { sodium: { versionId: "v1" } } });
    inst.stub({ [`${API}/project/sodium`]: { status: 500, json: { description: "boom" } } });
    const res = inst.run("update-mods.js", ["--json"], HELD);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, true);
    assert.deepEqual(out.upToDate, []);
    assert.equal(out.failed.length, 1);
    assert.equal(out.failed[0].slug, "sodium");
  }),
);

test(
  "a mod with no build for the target version is a failure",
  withInstance((inst) => {
    seed(inst, []);
    const out = lastJson(inst.run("update-mods.js", ["--json"], HELD).stdout);
    assert.deepEqual(out.upToDate, []);
    assert.equal(out.failed[0].slug, "sodium");
    assert.match(out.failed[0].error, /No compatible versions/);
  }),
);

test(
  "updating one mod that could not be checked fails the command",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: { sodium: { versionId: "v1" } } });
    inst.stub({ [`${API}/project/sodium`]: { status: 500, json: { description: "boom" } } });
    const res = inst.run("update-mod.js", ["sodium", "--json"], HELD);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "update-failed");
    assert.equal(res.code, 1);
  }),
);

// ── dependencies and the swap ──

const CDN = "https://cdn/";
function updateWithDependency(inst, { depInstalled }) {
  const mods = { sodium: { versionId: "old", filename: "sodium-old.jar" } };
  if (depInstalled) mods["fabric-api"] = { versionId: "f1", filename: "fabric-api-1.jar" };
  inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods });
  fs.writeFileSync(path.join(inst.mods, "sodium-old.jar"), "OLD");
  if (depInstalled) fs.writeFileSync(path.join(inst.mods, "fabric-api-1.jar"), "FABRIC");
  const jarHash = sha("sha512", "NEWJAR");
  const table = {
    [`${API}/project/sodium`]: { json: { id: "sod", slug: "sodium" } },
    [`${API}/project/sod/version`]: {
      json: [
        version("new", {
          dependencies: [{ project_id: "DEP", dependency_type: "required" }],
          files: [{ primary: true, url: `${CDN}sodium-new.jar`, hashes: { sha512: jarHash } }],
        }),
      ],
    },
    [`${CDN}sodium-new.jar`]: { bodyBase64: b64("NEWJAR"), headers: {} },
    [`${API}/project/DEP`]: { json: { id: "DEP", slug: "fabric-api" } },
    [`${API}/project/DEP/version`]: {
      json: [version("dep1", { files: [{ primary: true, url: `${CDN}fabric-api-1.jar`, hashes: { sha512: sha("sha512", "FABRIC") } }] })],
    },
    [`${CDN}fabric-api-1.jar`]: { bodyBase64: b64("FABRIC"), headers: {} },
  };
  if (depInstalled) {
    table[`${API}/project/fabric-api`] = { json: { id: "DEP", slug: "fabric-api" } };
    table[`${API}/project/DEP/version`] = { json: [version("f1", { files: [{ primary: true, url: `${CDN}fabric-api-1.jar` }] })] };
  }
  inst.stub(table);
}

test(
  "a required dependency the new build needs is installed with the update",
  withInstance((inst) => {
    updateWithDependency(inst, { depInstalled: false });
    const res = inst.run("update-mods.js", ["--json"], HELD);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, true, res.stderr);
    assert.deepEqual(out.failed, []);
    assert.deepEqual(out.updated.map((u) => u.slug), ["sodium"]);
    assert.equal(fs.readFileSync(path.join(inst.mods, "fabric-api-1.jar"), "utf8"), "FABRIC");
    assert.equal(inst.readManifest().mods["fabric-api"].versionId, "dep1");
    assert.equal(fs.existsSync(path.join(inst.mods, "sodium-old.jar")), false, "the old build is gone");
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium-new.jar"), "utf8"), "NEWJAR");
  }),
);

test(
  "a dependency that is already installed is left alone",
  withInstance((inst) => {
    updateWithDependency(inst, { depInstalled: true });
    const res = inst.run("update-mods.js", ["--json"], HELD);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, true, res.stderr);
    assert.deepEqual(out.failed, []);
    assert.equal(fs.readFileSync(path.join(inst.mods, "fabric-api-1.jar"), "utf8"), "FABRIC");
    assert.equal(inst.requests().includes(`${CDN}fabric-api-1.jar`), false, "its jar was not downloaded again");
  }),
);

test(
  "an update that keeps the file name replaces the jar and does not delete the new one",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: { sodium: { versionId: "old", filename: "sodium.jar" } } });
    fs.writeFileSync(path.join(inst.mods, "sodium.jar"), "OLD");
    inst.stub({
      [`${API}/project/sodium`]: { json: { id: "sod", slug: "sodium" } },
      [`${API}/project/sod/version`]: {
        json: [version("new", { files: [{ primary: true, url: `${CDN}sodium.jar`, hashes: { sha512: sha("sha512", "NEWJAR") } }] })],
      },
      [`${CDN}sodium.jar`]: { bodyBase64: b64("NEWJAR"), headers: {} },
    });
    const out = lastJson(inst.run("update-mods.js", ["--json"], HELD).stdout);
    assert.deepEqual(out.failed, []);
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium.jar"), "utf8"), "NEWJAR");
    assert.equal(inst.readManifest().mods.sodium.versionId, "new");
  }),
);

// ── add-mod trusts a file on disk only when it is the published one ──

function addTable(files) {
  return {
    [`${API}/project/sodium`]: { json: { id: "sod", slug: "sodium" } },
    [`${API}/project/sod/version`]: { json: [version("v1", { files })] },
    [`${CDN}sodium-1.0.jar`]: { bodyBase64: b64("GOODJAR"), headers: {} },
  };
}

test(
  "add-mod replaces a same-named file whose checksum does not match",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: {} });
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "PLANTED");
    inst.stub(addTable([{ primary: true, url: `${CDN}sodium-1.0.jar`, hashes: { sha512: sha("sha512", "GOODJAR") } }]));
    const res = inst.run("add-mod.js", ["sodium", "--json"], HELD);
    assert.equal(lastJson(res.stdout).ok, true, res.stderr);
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium-1.0.jar"), "utf8"), "GOODJAR");
  }),
);

test(
  "add-mod keeps a same-named file that matches the published checksum",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: {} });
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "GOODJAR");
    inst.stub(addTable([{ primary: true, url: `${CDN}sodium-1.0.jar`, hashes: { sha512: sha("sha512", "GOODJAR") } }]));
    const res = inst.run("add-mod.js", ["sodium", "--json"], HELD);
    assert.equal(lastJson(res.stdout).ok, true, res.stderr);
    assert.equal(inst.requests().includes(`${CDN}sodium-1.0.jar`), false, "no download was needed");
    assert.equal(inst.readManifest().mods.sodium.versionId, "v1");
  }),
);

test(
  "add-mod does not trust an existing file when no checksum is published",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: {} });
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "UNKNOWN");
    inst.stub(addTable([{ primary: true, url: `${CDN}sodium-1.0.jar` }]));
    const res = inst.run("add-mod.js", ["sodium", "--json"], HELD);
    assert.equal(lastJson(res.stdout).ok, true, res.stderr);
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium-1.0.jar"), "utf8"), "GOODJAR");
  }),
);

test(
  "add-mod installs the release, not a newer beta",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.5", modLoader: "fabric", mods: {} });
    inst.stub({
      [`${API}/project/sodium`]: { json: { id: "sod", slug: "sodium" } },
      [`${API}/project/sod/version`]: {
        json: [
          version("beta", { version_type: "beta", date_published: "2026-05-01T00:00:00Z", files: [{ primary: true, url: `${CDN}beta.jar` }] }),
          version("release", { files: [{ primary: true, url: `${CDN}release.jar` }] }),
        ],
      },
      [`${CDN}release.jar`]: { bodyBase64: b64("R"), headers: {} },
      [`${CDN}beta.jar`]: { bodyBase64: b64("B"), headers: {} },
    });
    const res = inst.run("add-mod.js", ["sodium", "--json"], HELD);
    assert.equal(lastJson(res.stdout).ok, true, res.stderr);
    assert.equal(inst.readManifest().mods.sodium.versionId, "release");
  }),
);

// ── toggle reads the manifest as untrusted ──

test(
  "a manifest file name that is not a plain name is refused",
  withInstance((inst) => {
    inst.writeManifest({ mods: { sodium: { versionId: "v1", filename: "../../outside.jar" } } });
    const res = inst.run("toggle-mod.js", ["sodium", "--disable", "--json"], HELD);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.equal(out.code, "manifest");
  }),
);
