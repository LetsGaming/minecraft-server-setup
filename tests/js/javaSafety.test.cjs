// Installing and switching Java: JDK names are data from a remote index, and
// the server is only pointed at a new JDK once the update is confirmed and backed up.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { makeInstance, b64, sha } = require("./helpers.cjs");
const { assertJabbaCandidate, jabbaInstallCommand } = require("../../src/scripts/update/lib/jabba.js");

test("a JDK name is plain characters or it is refused", () => {
  for (const ok of ["temurin@21.0.4", "adopt@17.0.9", "temurin@21.0.4+7", "adopt@1.8.0-292"]) {
    assert.equal(assertJabbaCandidate(ok), ok);
  }
  for (const bad of ["x; rm -rf ~", "a b", "$(id)", "`id`", "a'b", 'a"b', "a|b", "a&b", "a\nb", "", null, undefined, 7]) {
    assert.throws(() => assertJabbaCandidate(bad), /Refusing a JDK name/, JSON.stringify(bad));
  }
});

test("the name reaches bash as an argument, not as part of the command text", () => {
  const [file, args] = jabbaInstallCommand("temurin@21.0.4");
  assert.equal(file, "bash");
  assert.equal(args[0], "-c");
  assert.ok(!args[1].includes("temurin"), "the script text never contains the name");
  assert.deepEqual(args.slice(2), ["_", "temurin@21.0.4"]);
  assert.throws(() => jabbaInstallCommand("a; b"), /Refusing a JDK name/);
});

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

function interactiveWorld(inst) {
  inst.writeManifest({ gameVersion: "1.21.1", modLoader: "vanilla", mods: {} });
  inst.stub({
    [MOJANG]: { json: { latest: { release: "1.21.5", snapshot: "1.21.5" }, versions: [{ id: "1.21.5", url: META }] } },
    [META]: { json: { javaVersion: { majorVersion: 21 }, downloads: { server: { url: JAR_URL, sha1: sha("sha1", "JAR") } } } },
    [JAR_URL]: { bodyBase64: b64("JAR"), headers: {} },
  });
  const home = path.join(inst.root, "home");
  fs.mkdirSync(path.join(home, ".jabba", "jdk", "adopt@21.0.1"), { recursive: true });
  const variables = path.join(inst.server, "variables.txt");
  fs.writeFileSync(variables, 'JAVA="/old/jdk17/bin/java"\n');
  return { env: { HOME: home, USERPROFILE: home }, variables };
}

test(
  "an interactive update whose backup fails leaves the server's JAVA alone",
  withInstance((inst) => {
    const { env, variables } = interactiveWorld(inst);
    // No backup script exists in the scratch tree, so the backup step fails.
    const res = inst.run("update-server.js", ["1.21.5", "--yes"], env);
    assert.equal(res.code, 1);
    assert.match(res.stdout + res.stderr, /Backup failed/);
    assert.equal(fs.readFileSync(variables, "utf8"), 'JAVA="/old/jdk17/bin/java"\n');
    assert.equal(fs.existsSync(path.join(inst.server, "server.jar")), false, "nothing was installed");
  }),
);

test(
  "an interactive update points the server at the new JDK once the backup is done",
  { skip: process.platform === "win32" && "the Java path check accepts POSIX paths only" },
  withInstance((inst) => {
    const { env, variables } = interactiveWorld(inst);
    fs.mkdirSync(path.join(inst.scripts, "backup"), { recursive: true });
    fs.writeFileSync(path.join(inst.scripts, "backup", "backup.sh"), "exit 0\n");
    const res = inst.run("update-server.js", ["1.21.5", "--yes"], env);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    assert.match(fs.readFileSync(variables, "utf8"), /^JAVA=".*adopt@21\.0\.1\/bin\/java"$/m);
    assert.equal(fs.readFileSync(path.join(inst.server, "server.jar"), "utf8"), "JAR");
  }),
);
