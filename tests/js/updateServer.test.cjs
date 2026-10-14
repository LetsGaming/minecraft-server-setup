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
  "--plan counts sit! as available when Modrinth has a build, so an upgrade keeps it",
  withInstance((inst) => {
    seed(inst, { mods: { "sit!": { versionId: "s1" } } });
    const table = JSON.parse(fs.readFileSync(inst.stubFile, "utf8"));
    table[PROJECT("sit!")] = { json: { id: "sitid" } };
    table[VERSIONS("sitid")] = {
      json: [{
        id: "s2",
        name: "Sit!",
        date_published: "2026-10-01T00:00:00Z",
        game_versions: ["1.21.5"],
        loaders: ["vanilla"],
        files: [{ primary: true, url: "https://cdn/sit.jar", hashes: { sha512: "ab" } }],
      }],
    };
    inst.stub(table);
    const res = inst.run("update-server.js", ["1.21.5", "--plan", "--json"], withJava(inst, 21));
    assert.equal(res.code, 0, res.stderr);
    const [out] = lines(res.stdout);
    assert.equal(out.ok, true);
    assert.deepEqual(out.unavailable, []);
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

// S-007: an upgrade that needs a newer Java points the server at it.
test("setServerJava rewrites JAVA= in the server's variables.txt, and only there", () => {
  const { setServerJava } = require("../../src/scripts/update/update-server.js");
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "java-"));
  try {
    const file = path.join(dir, "variables.txt");
    fs.writeFileSync(file, 'JAVA_ARGS="-Xmx4G"\nJAVA="/old/jdk17/bin/java"\nUSE_FABRIC="false"\n', { mode: 0o640 });
    assert.equal(setServerJava(dir, "/home/mc/.jabba/jdk/temurin@21.0.5/bin/java"), true);
    assert.equal(
      fs.readFileSync(file, "utf8"),
      'JAVA_ARGS="-Xmx4G"\nJAVA="/home/mc/.jabba/jdk/temurin@21.0.5/bin/java"\nUSE_FABRIC="false"\n',
    );
    assert.equal(fs.statSync(file).mode & 0o777, 0o640);
    assert.throws(() => setServerJava(dir, '/x"; rm -rf ~; "'), /unusual Java path/);
    fs.writeFileSync(file, 'USE_FABRIC="false"\n');
    assert.equal(setServerJava(dir, "/j/bin/java"), false, "no JAVA= line: not a vanilla start");
    assert.equal(setServerJava(path.join(dir, "missing"), "/j/bin/java"), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("JDK names sort by version, not as strings", () => {
  const { compareJdkNames } = require("../../src/scripts/update/update-server.js");
  assert.deepEqual(
    ["temurin@21.0.9", "temurin@21.0.10", "adopt@21.0.2"].sort(compareJdkNames),
    ["temurin@21.0.10", "temurin@21.0.9", "adopt@21.0.2"],
  );
});
