// What setup's downloads trust and report: files from a remote API are bounded,
// verified and written through a temporary file, and a mod that did not arrive
// fails the step instead of passing with a log line.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { Readable } = require("node:stream");
const { spawnSync } = require("node:child_process");
const axios = require("axios");

const REPO = path.resolve(__dirname, "..", "..");
const STUB = path.join(__dirname, "axiosStub.cjs");
const { downloadFile } = require("../../src/setup/download/download_utils.js");
const lib = require("../../src/scripts/update/lib/download.js");

const sha1 = (text) => crypto.createHash("sha1").update(text).digest("hex");
const sha512 = (text) => crypto.createHash("sha512").update(text).digest("hex");

function scratch(fn) {
  return async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-dl-"));
    const realGet = axios.get;
    try {
      await fn(dir);
    } finally {
      axios.get = realGet;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  };
}

/** axios.get answering with a stream of `chunks`; records the options it was called with. */
function serve(chunks, seen = {}) {
  axios.get = async (url, options) => {
    seen.url = url;
    seen.options = options;
    return { status: 200, headers: {}, data: Readable.from(chunks.map((c) => Buffer.from(c))) };
  };
  return seen;
}

const quiet = async (fn) => {
  const log = console.log;
  const error = console.error;
  console.log = () => {};
  console.error = () => {};
  try {
    return await fn();
  } finally {
    console.log = log;
    console.error = error;
  }
};

// ── downloadFile ──

test(
  "downloadFile writes the file only after its SHA-1 matched, and leaves no temp file",
  scratch(async (dir) => {
    const target = path.join(dir, "pack.zip");
    serve(["hello ", "world"]);
    await quiet(() => downloadFile("https://cdn.example/pack.zip", target, 11, { sha1: sha1("hello world") }));
    assert.equal(fs.readFileSync(target, "utf8"), "hello world");
    assert.equal(fs.existsSync(`${target}.part`), false);
  }),
);

test(
  "a SHA-1 mismatch rejects the download and leaves nothing behind",
  scratch(async (dir) => {
    const target = path.join(dir, "pack.zip");
    serve(["tampered"]);
    await assert.rejects(
      quiet(() => downloadFile("https://cdn.example/pack.zip", target, 8, { sha1: sha1("original") })),
      /sha1 verification/,
    );
    assert.deepEqual(fs.readdirSync(dir), []);
  }),
);

test(
  "a download that ends short of its announced size is rejected",
  scratch(async (dir) => {
    const target = path.join(dir, "pack.zip");
    serve(["short"]);
    await assert.rejects(quiet(() => downloadFile("https://cdn.example/pack.zip", target, 100)), /ended after 5 of 100 bytes/);
    assert.deepEqual(fs.readdirSync(dir), []);
  }),
);

test(
  "a body over the size cap is rejected",
  scratch(async (dir) => {
    const target = path.join(dir, "pack.zip");
    serve(["0123456789", "0123456789"]);
    await assert.rejects(quiet(() => downloadFile("https://cdn.example/pack.zip", target, 0, { maxBytes: 15 })), /exceeded the 15 byte limit/);
    assert.deepEqual(fs.readdirSync(dir), []);
  }),
);

test(
  "the request has a timeout, a size cap and https-only redirects",
  scratch(async (dir) => {
    const seen = serve(["x"]);
    await quiet(() => downloadFile("https://cdn.example/a.bin", path.join(dir, "a.bin"), 1));
    assert.ok(seen.options.timeout > 0, "a timeout for the response to start");
    assert.ok(seen.options.signal, "a deadline for the whole transfer");
    assert.ok(seen.options.maxContentLength > 0 && seen.options.maxBodyLength > 0, "a size cap");
    assert.equal(typeof seen.options.beforeRedirect, "function");
    assert.throws(() => seen.options.beforeRedirect({ protocol: "http:", hostname: "evil.example" }), /Refusing a redirect/);
    assert.doesNotThrow(() => seen.options.beforeRedirect({ protocol: "https:", hostname: "cdn.example" }));
  }),
);

test(
  "a plain http download is refused before any request",
  scratch(async (dir) => {
    const seen = serve(["x"]);
    await assert.rejects(quiet(() => downloadFile("http://cdn.example/a.bin", path.join(dir, "a.bin"), 1)), /Refusing a http download/);
    assert.equal(seen.url, undefined);
  }),
);

test(
  "a link left at the temp path is replaced, never written through",
  scratch(async (dir) => {
    const victim = path.join(dir, "victim.txt");
    fs.writeFileSync(victim, "keep me");
    const target = path.join(dir, "pack.zip");
    try {
      fs.symlinkSync(victim, `${target}.part`);
    } catch {
      return; // no permission to make links on this host
    }
    serve(["new data"]);
    await quiet(() => downloadFile("https://cdn.example/pack.zip", target, 8));
    assert.equal(fs.readFileSync(victim, "utf8"), "keep me");
    assert.equal(fs.readFileSync(target, "utf8"), "new data");
  }),
);

// ── the shared downloader ──

test("the shared downloader refuses plain http and redirects away from https", async () => {
  await assert.rejects(lib.downloadToTemp("http://cdn.example/a.jar", path.join(os.tmpdir(), "never.tmp")), /Refusing a http download/);
  assert.throws(() => lib.httpsOnlyRedirect({ protocol: "ftp:", hostname: "x" }), /Refusing a redirect/);
  assert.doesNotThrow(() => lib.httpsOnlyRedirect({ protocol: "https:", hostname: "x" }));
});

test(
  "fileMatchesHash trusts a file only when a published digest agrees with it",
  scratch(async (dir) => {
    const file = path.join(dir, "m.jar");
    fs.writeFileSync(file, "JAR");
    assert.equal(lib.fileMatchesHash(file, { sha512: sha512("JAR") }), true);
    assert.equal(lib.fileMatchesHash(file, { sha1: sha1("JAR") }), true);
    assert.equal(lib.fileMatchesHash(file, { sha512: sha512("OTHER") }), false);
    assert.equal(lib.fileMatchesHash(file, {}), false, "no digest, no trust");
    assert.equal(lib.fileMatchesHash(path.join(dir, "missing.jar"), { sha1: sha1("JAR") }), false);
  }),
);

// ── download_mods.js as setup runs it ──

const API = "https://api.modrinth.com/v2";
const CDN = "https://cdn.modrinth.com/data/x/versions";
const b64 = (text) => Buffer.from(text).toString("base64");

/** A copy of the setup downloader and the shared library, with its own manifest folder. */
function setupTree(dir, table) {
  for (const sub of [["src", "setup", "download"], ["src", "scripts", "update", "lib"]]) {
    fs.cpSync(path.join(REPO, ...sub), path.join(dir, ...sub), {
      recursive: true,
      filter: (src) => !src.includes("node_modules"),
    });
  }
  fs.mkdirSync(path.join(dir, "src", "scripts", "common"), { recursive: true });
  const stub = path.join(dir, "stub.json");
  fs.writeFileSync(stub, JSON.stringify(table));
  const out = path.join(dir, "mods-out");
  const run = (slugs, extraArgs = [], logFile = null) => {
    fs.writeFileSync(path.join(dir, "slugs.txt"), slugs.join("\n"));
    const res = spawnSync(
      process.execPath,
      [
        path.join(dir, "src", "setup", "download", "download_mods.js"),
        `--downloadDir=${out}`,
        `--modSlugsFile=${path.join(dir, "slugs.txt")}`,
        "--mcVersion=1.21.5",
        "--modLoader=fabric",
        ...extraArgs,
      ],
      { encoding: "utf8", env: { ...process.env, NODE_OPTIONS: `--require ${STUB.split(path.sep).join("/")}`, AXIOS_STUB_FILE: stub, ...(logFile ? { AXIOS_STUB_LOG: logFile } : {}) } },
    );
    return { code: res.status, out: res.stdout + res.stderr };
  };
  return { run, out, manifest: path.join(dir, "src", "scripts", "common", "downloaded_versions.json") };
}

const build = (id, file, extra = {}) => ({
  id,
  name: id,
  date_published: "2026-01-01T00:00:00Z",
  version_type: "release",
  game_versions: ["1.21.5"],
  loaders: ["fabric"],
  dependencies: [],
  files: [file],
  ...extra,
});

test(
  "setup downloads a mod, verifies it and records it",
  scratch(async (dir) => {
    const t = setupTree(dir, {
      [`${API}/project/sodium/version`]: { json: [build("v1", { primary: true, url: `${CDN}/sodium.jar`, hashes: { sha512: sha512("JAR") } })] },
      [`${CDN}/sodium.jar`]: { bodyBase64: b64("JAR"), headers: {} },
    });
    const r = t.run(["sodium"]);
    assert.equal(r.code, 0, r.out);
    assert.equal(fs.readFileSync(path.join(t.out, "sodium.jar"), "utf8"), "JAR");
    assert.equal(JSON.parse(fs.readFileSync(t.manifest, "utf8")).mods.sodium.versionId, "v1");
  }),
);

test(
  "a mod with no build for the version fails the step",
  scratch(async (dir) => {
    const t = setupTree(dir, { [`${API}/project/sodium/version`]: { json: [] } });
    const r = t.run(["sodium"]);
    assert.equal(r.code, 1);
    assert.match(r.out, /FAILED sodium: no compatible version/);
  }),
);

test(
  "a mod whose build has no published checksum is not downloaded and fails the step",
  scratch(async (dir) => {
    const t = setupTree(dir, {
      [`${API}/project/sodium/version`]: { json: [build("v1", { primary: true, url: `${CDN}/sodium.jar` })] },
      [`${CDN}/sodium.jar`]: { bodyBase64: b64("JAR"), headers: {} },
    });
    const r = t.run(["sodium"]);
    assert.equal(r.code, 1);
    assert.match(r.out, /publishes no checksum/);
    assert.equal(fs.existsSync(path.join(t.out, "sodium.jar")), false);
  }),
);

test(
  "a download that fails verification fails the step and leaves no jar",
  scratch(async (dir) => {
    const t = setupTree(dir, {
      [`${API}/project/sodium/version`]: { json: [build("v1", { primary: true, url: `${CDN}/sodium.jar`, hashes: { sha512: sha512("EXPECTED") } })] },
      [`${CDN}/sodium.jar`]: { bodyBase64: b64("SOMETHING ELSE"), headers: {} },
    });
    const r = t.run(["sodium"]);
    assert.equal(r.code, 1);
    assert.match(r.out, /failed sha512 verification/);
    assert.deepEqual(fs.existsSync(t.out) ? fs.readdirSync(t.out) : [], []);
  }),
);

test(
  "a required dependency that cannot be fetched fails the step although the mod arrived",
  scratch(async (dir) => {
    const t = setupTree(dir, {
      [`${API}/project/sodium/version`]: {
        json: [
          build("v1", { primary: true, url: `${CDN}/sodium.jar`, hashes: { sha512: sha512("JAR") } }, {
            dependencies: [{ project_id: "DEP", dependency_type: "required" }],
          }),
        ],
      },
      [`${CDN}/sodium.jar`]: { bodyBase64: b64("JAR"), headers: {} },
      [`${API}/project/DEP/version`]: { json: [] },
    });
    const r = t.run(["sodium"]);
    assert.equal(r.code, 1);
    assert.match(r.out, /FAILED DEP/);
    assert.equal(fs.existsSync(path.join(t.out, "sodium.jar")), true);
  }),
);

test(
  "--exclude skips exactly the listed slugs and never requests them",
  scratch(async (dir) => {
    const log = path.join(dir, "requests.log");
    const t = setupTree(dir, {
      [`${API}/project/lithium/version`]: { json: [build("v1", { primary: true, url: `${CDN}/lithium.jar`, hashes: { sha512: sha512("JAR") } })] },
      [`${CDN}/lithium.jar`]: { bodyBase64: b64("JAR"), headers: {} },
    });
    const r = t.run(["sodium", "lithium"], ["--exclude", "sodium"], log);
    assert.equal(r.code, 0, r.out);
    const requests = fs.readFileSync(log, "utf8");
    assert.doesNotMatch(requests, /sodium/);
    assert.match(requests, /project\/lithium\/version/);
    assert.equal(fs.existsSync(path.join(t.out, "lithium.jar")), true);
  }),
);

test(
  "--exclude covering every requested mod is a clean no-op",
  scratch(async (dir) => {
    const t = setupTree(dir, {});
    const r = t.run(["sodium"], ["--exclude", "sodium,other"]);
    assert.equal(r.code, 0, r.out);
  }),
);

test(
  "setup prefers a release over a newer beta",
  scratch(async (dir) => {
    const t = setupTree(dir, {
      [`${API}/project/sodium/version`]: {
        json: [
          build("beta", { primary: true, url: `${CDN}/beta.jar`, hashes: { sha512: sha512("B") } }, { version_type: "beta", date_published: "2026-06-01T00:00:00Z" }),
          build("release", { primary: true, url: `${CDN}/release.jar`, hashes: { sha512: sha512("R") } }),
        ],
      },
      [`${CDN}/beta.jar`]: { bodyBase64: b64("B"), headers: {} },
      [`${CDN}/release.jar`]: { bodyBase64: b64("R"), headers: {} },
    });
    const r = t.run(["sodium"]);
    assert.equal(r.code, 0, r.out);
    assert.equal(JSON.parse(fs.readFileSync(t.manifest, "utf8")).mods.sodium.versionId, "release");
  }),
);

// ── download_modpack.js ──

function modpackTree(dir, gameVersions, hashes) {
  for (const sub of [["src", "setup", "download"], ["src", "scripts", "update", "lib"]]) {
    fs.cpSync(path.join(REPO, ...sub), path.join(dir, ...sub), { recursive: true, filter: (src) => !src.includes("node_modules") });
  }
  fs.mkdirSync(path.join(dir, "src", "scripts", "common"), { recursive: true });
  fs.writeFileSync(path.join(dir, "src", "setup", "download", "json", "curseforge_variables.json"), JSON.stringify({ pack_id: "123", api_key: "key" }));
  const CF = "https://api.curseforge.com/v1/mods/123";
  const stub = path.join(dir, "stub.json");
  fs.writeFileSync(
    stub,
    JSON.stringify({
      [CF]: { json: { data: { mainFileId: 1 } } },
      [`${CF}/files/1`]: { json: { data: { serverPackFileId: 2 } } },
      [`${CF}/files/2`]: {
        json: { data: { id: 2, fileLength: 4, downloadUrl: "https://cdn.example/pack.zip", gameVersions, hashes } },
      },
      "https://cdn.example/pack.zip": { bodyBase64: b64("PACK"), headers: {} },
    }),
  );
  const res = spawnSync(process.execPath, [path.join(dir, "src", "setup", "download", "download_modpack.js")], {
    encoding: "utf8",
    env: { ...process.env, NODE_OPTIONS: `--require ${STUB.split(path.sep).join("/")}`, AXIOS_STUB_FILE: stub },
  });
  const manifest = path.join(dir, "src", "scripts", "common", "downloaded_versions.json");
  return {
    code: res.status,
    out: res.stdout + res.stderr,
    manifest: fs.existsSync(manifest) ? JSON.parse(fs.readFileSync(manifest, "utf8")) : null,
    zip: path.join(dir, "src", "setup", "download", "temp", "server-pack.zip"),
  };
}

test(
  "a server pack that names no loader or version records neither, not the word none",
  scratch(async (dir) => {
    const r = modpackTree(dir, ["Server"], [{ value: sha1("PACK"), algo: 1 }]);
    assert.equal(r.code, 0, r.out);
    assert.equal(fs.readFileSync(r.zip, "utf8"), "PACK");
    assert.equal(r.manifest.modLoader, undefined);
    assert.equal(r.manifest.gameVersion, undefined);
    assert.equal(r.manifest.modpack["123"], 2);
    assert.match(r.out, /could not tell the mod loader/);
  }),
);

test(
  "a server pack's loader and version are recorded when they are listed",
  scratch(async (dir) => {
    const r = modpackTree(dir, ["1.21.1", "NeoForge", "Server"], [{ value: sha1("PACK"), algo: 1 }]);
    assert.equal(r.code, 0, r.out);
    assert.equal(r.manifest.modLoader, "NeoForge");
    assert.equal(r.manifest.gameVersion, "1.21.1");
  }),
);

test(
  "a server pack whose SHA-1 differs from CurseForge's is rejected and not kept",
  scratch(async (dir) => {
    const r = modpackTree(dir, ["1.21.1", "Fabric"], [{ value: sha1("SOMETHING ELSE"), algo: 1 }]);
    assert.equal(r.code, 1);
    assert.match(r.out, /sha1 verification/);
    assert.equal(fs.existsSync(r.zip), false);
    assert.equal(fs.existsSync(`${r.zip}.part`), false);
  }),
);
