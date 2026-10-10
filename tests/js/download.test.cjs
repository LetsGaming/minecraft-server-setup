const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { Readable } = require("stream");
const { makeInstance, b64, sha, lastJson } = require("./helpers.cjs");

const API = "https://api.modrinth.com/v2";
const CDN = "https://cdn.modrinth.com/data/AANobbMI/versions/v1";

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

function modTable({ fileUrl, hashes, body = "JARBYTES" }) {
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
          files: [{ primary: true, url: fileUrl, hashes }],
        },
      ],
    },
    [fileUrl]: { bodyBase64: b64(body), headers: {} },
  };
}

const base = { gameVersion: "1.21.4", modLoader: "fabric", mods: {} };

test(
  "add-mod accepts a download whose sha512 matches",
  withInstance((inst) => {
    inst.writeManifest(base);
    inst.stub(modTable({ fileUrl: `${CDN}/sodium-1.0.jar`, hashes: { sha512: sha("sha512", "JARBYTES") } }));
    const res = inst.run("add-mod.js", ["--json", "--", "sodium"]);
    assert.equal(res.code, 0, res.stderr);
    assert.equal(lastJson(res.stdout).ok, true);
    assert.ok(fs.existsSync(path.join(inst.mods, "sodium-1.0.jar")));
  }),
);

test(
  "add-mod rejects a sha512 mismatch and leaves neither jar nor temp file",
  withInstance((inst) => {
    inst.writeManifest(base);
    inst.stub(modTable({ fileUrl: `${CDN}/sodium-1.0.jar`, hashes: { sha512: sha("sha512", "SOMETHING ELSE") } }));
    const res = inst.run("add-mod.js", ["--json", "--", "sodium"]);
    assert.equal(res.code, 1);
    const out = lastJson(res.stdout);
    assert.equal(out.ok, false);
    assert.match(out.error, /sha512/);
    assert.deepEqual(fs.readdirSync(inst.mods), []);
    assert.deepEqual(inst.readManifest().mods, {});
  }),
);

test(
  "add-mod refuses a filename that decodes into a path outside mods/",
  withInstance((inst) => {
    inst.writeManifest(base);
    inst.stub(modTable({ fileUrl: `${CDN}/%2F..%2F..%2Fevil.jar`, hashes: {} }));
    const res = inst.run("add-mod.js", ["--json", "--", "sodium"]);
    assert.equal(res.code, 1);
    assert.equal(lastJson(res.stdout).ok, false);
    assert.deepEqual(fs.readdirSync(inst.mods), []);
    assert.equal(fs.existsSync(path.join(inst.server, "evil.jar")), false);
    assert.equal(fs.existsSync(path.join(inst.root, "evil.jar")), false);
  }),
);

test(
  "add-mod treats a slug that looks like a flag as data after --",
  withInstance((inst) => {
    inst.writeManifest(base);
    inst.stub({ [`${API}/project/--json`]: { status: 404, json: {} } });
    const res = inst.run("add-mod.js", ["--json", "--", "--json"]);
    const out = lastJson(res.stdout);
    assert.equal(out.code, "not-found");
    assert.match(inst.requests()[0], /\/project\/--json$/);
  }),
);

test(
  "update-mods rejects a sha512 mismatch, keeps the old jar and reports the mod as failed",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "OLD");
    inst.writeManifest({
      ...base,
      mods: { sodium: { versionId: "ver0", filename: "sodium-1.0.jar" } },
    });
    inst.stub(
      modTable({
        fileUrl: `${CDN}/sodium-2.0.jar`,
        hashes: { sha512: sha("sha512", "NOT THE BODY") },
      }),
    );
    const out = lastJson(inst.run("update-mods.js", ["--json"]).stdout);
    assert.equal(out.failed.length, 1);
    assert.match(out.failed[0].error, /sha512/);
    assert.equal(fs.readFileSync(path.join(inst.mods, "sodium-1.0.jar"), "utf8"), "OLD");
    assert.deepEqual(fs.readdirSync(inst.mods).sort(), ["sodium-1.0.jar"]);
  }),
);

test(
  "update-mods verifies a matching sha512 and installs",
  withInstance((inst) => {
    fs.writeFileSync(path.join(inst.mods, "sodium-1.0.jar"), "OLD");
    inst.writeManifest({
      ...base,
      mods: { sodium: { versionId: "ver0", filename: "sodium-1.0.jar" } },
    });
    inst.stub(
      modTable({
        fileUrl: `${CDN}/sodium-2.0.jar`,
        hashes: { sha512: sha("sha512", "JARBYTES") },
      }),
    );
    const out = lastJson(inst.run("update-mods.js", ["--json"]).stdout);
    assert.equal(out.updated.length, 1);
    assert.ok(fs.existsSync(path.join(inst.mods, "sodium-2.0.jar")));
  }),
);

// ── lib/download.js in-process ───────────────────────────────────────────────

const downloadLib = path.resolve(__dirname, "..", "..", "src", "scripts", "update", "lib", "download.js");

function inProcess(t, table) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-dl-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const stubFile = path.join(dir, "stub.json");
  fs.writeFileSync(stubFile, JSON.stringify(table));
  process.env.AXIOS_STUB_FILE = stubFile;
  require("./axiosStub.cjs");
  return { dir, lib: require(downloadLib) };
}

test("safeFilenameFromUrl decodes first, then rejects separators and dot names", (t) => {
  const { lib } = inProcess(t, {});
  assert.equal(lib.safeFilenameFromUrl("https://cdn.example/a/b/My%20Mod-1.0.jar"), "My Mod-1.0.jar");
  for (const bad of [
    "https://cdn.example/a/%2F..%2Fx.jar",
    "https://cdn.example/a/..%5Cx.jar",
    "https://cdn.example/a/%2E%2E",
    "https://cdn.example/a/",
    "https://cdn.example/a/bad%00.jar",
    "https://cdn.example/a/%E0%A4%A.jar",
  ]) {
    assert.throws(() => lib.safeFilenameFromUrl(bad), /Refusing/, bad);
  }
});

test("downloadVerified renames into place only after the sha1 matches", async (t) => {
  const url = "https://piston-data.mojang.com/v1/objects/x/server.jar";
  const { dir, lib } = inProcess(t, { [url]: { bodyBase64: b64("SERVER"), headers: {} } });
  const target = path.join(dir, "server.jar");
  fs.writeFileSync(target, "ORIGINAL");

  await assert.rejects(lib.downloadVerified(url, target, { sha1: sha("sha1", "WRONG") }), /sha1/);
  assert.equal(fs.readFileSync(target, "utf8"), "ORIGINAL");
  assert.equal(fs.existsSync(`${target}.tmp`), false);

  await lib.downloadVerified(url, target, { sha1: sha("sha1", "SERVER") });
  assert.equal(fs.readFileSync(target, "utf8"), "SERVER");
  assert.equal(fs.existsSync(`${target}.tmp`), false);
});

test("downloadToTemp enforces the size cap and cleans up", async (t) => {
  const url = "https://cdn.example/big.jar";
  const { dir, lib } = inProcess(t, { [url]: { bodyBase64: b64("x".repeat(100)), headers: {} } });
  const temp = path.join(dir, "big.jar.tmp");
  await assert.rejects(lib.downloadToTemp(url, temp, { maxBytes: 50 }), /limit/);
  assert.equal(fs.existsSync(temp), false);
});

test("downloadToTemp cleans up when the body stream errors", async (t) => {
  const url = "https://cdn.example/broken.jar";
  const { dir, lib } = inProcess(t, { [url]: { bodyBase64: b64("abc"), headers: {} } });
  const Module = require("module");
  const temp = path.join(dir, "broken.jar.tmp");
  const broken = new Readable({
    read() {
      this.push(Buffer.from("partial"));
      this.destroy(new Error("connection reset"));
    },
  });
  const realGet = Module._load;
  Module._load = function (request, ...rest) {
    if (request === "axios") return () => Promise.resolve({ headers: {}, data: broken });
    return realGet.call(this, request, ...rest);
  };
  delete require.cache[downloadLib];
  try {
    const fresh = require(downloadLib);
    await assert.rejects(fresh.downloadToTemp(url, temp), /connection reset/);
  } finally {
    Module._load = realGet;
    delete require.cache[downloadLib];
  }
  assert.equal(fs.existsSync(temp), false);
});
