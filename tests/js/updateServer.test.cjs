const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { makeInstance, b64, sha } = require("./helpers.cjs");

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

const MOJANG = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
const META = "https://meta.example/1.21.5.json";
const JAR_URL = "https://dl.example/server.jar";
const PROJECT = (slug) => `https://api.modrinth.com/v2/project/${slug}`;
const VERSIONS = (id) => `https://api.modrinth.com/v2/project/${id}/version`;

function seed(inst, { mods = {}, jarBody = "JAR", jarSha = "JAR" } = {}) {
  inst.writeManifest({ gameVersion: "1.21.1", modLoader: "vanilla", mods });
  inst.stub({
    [MOJANG]: {
      json: {
        latest: { release: "1.21.5", snapshot: "1.21.5" },
        versions: [{ id: "1.21.5", url: META }],
      },
    },
    [META]: {
      json: {
        javaVersion: { majorVersion: 21 },
        downloads: { server: { url: JAR_URL, sha1: sha("sha1", jarSha) } },
      },
    },
    [JAR_URL]: { bodyBase64: b64(jarBody), headers: {} },
    [PROJECT("sodium")]: { json: { id: "sod" } },
    [VERSIONS("sod")]: { json: [] },
  });
}

function withJava(inst, major) {
  const home = path.join(inst.root, "home");
  fs.mkdirSync(path.join(home, ".jabba", "jdk", `adopt@${major}.0.1`), { recursive: true });
  return { HOME: home, USERPROFILE: home };
}

const lines = (stdout) => stdout.trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));

test(
  "--plan reports the target, the Java it needs and each mod's verdict, and changes nothing",
  withInstance((inst) => {
    seed(inst, { mods: { sodium: { versionId: "v1" } } });
    const env = withJava(inst, 17);
    const res = inst.run("update-server.js", ["1.21.5", "--plan", "--json"], env);
    assert.equal(res.code, 0, res.stderr);
    const [out] = lines(res.stdout);
    assert.equal(out.ok, true);
    assert.equal(out.current, "1.21.1");
    assert.equal(out.target, "1.21.5");
    assert.deepEqual(out.java, { required: "21", installed: false });
    assert.deepEqual(out.unavailable, ["sodium"]);
    assert.equal(inst.readManifest().gameVersion, "1.21.1", "the manifest is untouched");
    assert.equal(fs.existsSync(path.join(inst.server, "server.jar")), false, "no jar is written");
  }),
);

test(
  "--plan sees an installed Java",
  withInstance((inst) => {
    seed(inst);
    const env = withJava(inst, 21);
    const res = inst.run("update-server.js", ["1.21.5", "--plan", "--json"], env);
    assert.deepEqual(lines(res.stdout)[0].java, { required: "21", installed: true });
  }),
);

test(
  "--apply swaps the jar first and records the version only afterwards",
  withInstance((inst) => {
    seed(inst);
    const env = withJava(inst, 21);
    const res = inst.run("update-server.js", ["1.21.5", "--apply", "--json"], env);
    assert.equal(res.code, 0, res.stderr);
    const events = lines(res.stdout);
    assert.deepEqual(events.map((e) => e.phase ?? "done"), ["java", "jar", "mods", "done"]);
    assert.equal(events.at(-1).ok, true);
    assert.equal(fs.readFileSync(path.join(inst.server, "server.jar"), "utf8"), "JAR");
    assert.equal(inst.readManifest().gameVersion, "1.21.5");
  }),
);

test(
  "a failed jar download leaves the recorded version alone",
  withInstance((inst) => {
    seed(inst, { jarBody: "TAMPERED", jarSha: "JAR" });
    const env = withJava(inst, 21);
    const res = inst.run("update-server.js", ["1.21.5", "--apply", "--json"], env);
    assert.equal(res.code, 1);
    const last = lines(res.stdout).at(-1);
    assert.equal(last.ok, false);
    assert.equal(inst.readManifest().gameVersion, "1.21.1", "the version is not recorded before the swap succeeds");
  }),
);

test(
  "--plan and --apply together are refused",
  withInstance((inst) => {
    seed(inst);
    const res = inst.run("update-server.js", ["--plan", "--apply", "--json"], withJava(inst, 21));
    assert.equal(res.code, 2);
    assert.equal(lines(res.stdout)[0].ok, false);
  }),
);

test("unavailableMods picks the statuses that mean no build", () => {
  const { unavailableMods } = require("../../src/scripts/update/update-server.js");
  const picked = unavailableMods({
    results: [
      { slug: "a", status: "up_to_date" },
      { slug: "b", status: "no_matching_version" },
      { slug: "c", status: "error" },
      { slug: "d", status: "update_available" },
    ],
  });
  assert.deepEqual(picked.map((m) => m.slug), ["b", "c"]);
});
