const test = require("node:test");
const assert = require("node:assert/strict");
const { makeInstance } = require("./helpers.cjs");

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

const PROJECT = (slug) => `https://api.modrinth.com/v2/project/${slug}`;
const VERSIONS = (id) => `https://api.modrinth.com/v2/project/${id}/version`;

function seed(inst) {
  inst.writeManifest({
    gameVersion: "1.21.1",
    modLoader: "fabric",
    mods: { sodium: { versionId: "v1" }, lithium: { versionId: "l1" } },
  });
  const version = (id) => ({
    id,
    name: `Release ${id}`,
    date_published: "2026-01-01T00:00:00Z",
    game_versions: ["1.21.5"],
    loaders: ["fabric"],
    files: [{ primary: true, url: `https://cdn/${id}.jar`, hashes: { sha512: "ab" } }],
  });
  inst.stub({
    [PROJECT("sodium")]: { json: { id: "sod" } },
    [VERSIONS("sod")]: { json: [version("v2")] },
    [PROJECT("lithium")]: { json: { id: "lit" } },
    [VERSIONS("lit")]: { json: [version("l1")] },
  });
}

test(
  "without --only every installed mod is checked",
  withInstance((inst) => {
    seed(inst);
    const res = inst.run("check-updates.js", ["1.21.5", "--json"]);
    const out = JSON.parse(res.stdout);
    assert.equal(out.mcVersion, "1.21.5");
    assert.deepEqual(out.results.map((r) => [r.slug, r.status]), [
      ["sodium", "update_available"],
      ["lithium", "up_to_date"],
    ]);
  }),
);

test(
  "--only checks a single slug and leaves the JSON shape unchanged",
  withInstance((inst) => {
    seed(inst);
    const res = inst.run("check-updates.js", ["--mcVersion=1.21.5", "--only=sodium", "--json"]);
    const out = JSON.parse(res.stdout);
    assert.deepEqual(Object.keys(out), ["mcVersion", "modLoader", "results"]);
    assert.equal(out.results.length, 1);
    assert.equal(out.results[0].slug, "sodium");
    assert.equal(out.results[0].latestVersionName, "Release v2");
    assert.ok(inst.requests().every((u) => u.endsWith("/sodium") || u.includes("/sod/")));
  }),
);

test(
  "--only with a slug that is not installed reports invalid_entry",
  withInstance((inst) => {
    seed(inst);
    const res = inst.run("check-updates.js", ["1.21.5", "--only=ghost", "--json"]);
    const out = JSON.parse(res.stdout);
    assert.equal(out.results.length, 1);
    assert.equal(out.results[0].status, "invalid_entry");
    assert.equal(inst.requests().length, 0);
  }),
);

test(
  "a slug with Modrinth's other characters (sit!) is looked up as is and reported available",
  withInstance((inst) => {
    inst.writeManifest({ gameVersion: "1.21.1", modLoader: "fabric", mods: { "sit!": { versionId: "s1" } } });
    inst.stub({
      [PROJECT("sit!")]: { json: { id: "sitid" } },
      [VERSIONS("sitid")]: {
        json: [{
          id: "s2",
          name: "Sit! 26.3",
          date_published: "2026-10-01T00:00:00Z",
          game_versions: ["26.3"],
          loaders: ["fabric"],
          files: [{ primary: true, url: "https://cdn/sit.jar", hashes: { sha512: "ab" } }],
        }],
      },
    });
    const res = inst.run("check-updates.js", ["--mcVersion=26.3", "--only=sit!", "--json"]);
    const out = JSON.parse(res.stdout);
    assert.deepEqual(out.results.map((r) => [r.slug, r.status, r.latestVersionId]), [["sit!", "update_available", "s2"]]);
    assert.ok(inst.requests().some((u) => u.endsWith("/project/sit!")), inst.requests().join("\n"));
  }),
);
