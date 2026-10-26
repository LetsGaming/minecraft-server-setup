"use strict";

const { test, before, after } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const crypto = require("crypto");
const { spawn } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "..", "src", "mirror", "prepare_mods.js");
const { chooseVersion } = require(SCRIPT);

const sha512 = (b) => crypto.createHash("sha512").update(b).digest("hex");

// A tiny Modrinth: two projects, one with a pin and one without.
const JARS = {
  "fabricplots-1.0.2+26.3.jar": Buffer.from("plots-1.0.2"),
  "fabricplots-1.1.0+26.3.jar": Buffer.from("plots-1.1.0"),
  "dimensional-inventories-2.2.2+26.3.jar": Buffer.from("di-2.2.2"),
};
let server;
let base;
let tamper = false;

function version(slug, number, filename, type = "release", date = "2026-09-01T00:00:00Z") {
  return {
    version_number: number,
    version_type: type,
    date_published: date,
    files: [{ primary: true, filename, url: `${base}/files/${filename}`, hashes: { sha512: sha512(JARS[filename]) } }],
  };
}

before(async () => {
  server = http.createServer((req, res) => {
    const u = new URL(req.url, "http://x");
    const m = u.pathname.match(/^\/project\/([^/]+)\/version$/);
    if (m) {
      const slug = m[1];
      const list =
        slug === "fabricplots"
          ? [
              version(slug, "1.1.0+26.3", "fabricplots-1.1.0+26.3.jar", "release", "2026-10-01T00:00:00Z"),
              version(slug, "1.0.2+26.3", "fabricplots-1.0.2+26.3.jar", "release", "2026-09-01T00:00:00Z"),
            ]
          : slug === "dimensional-inventories"
            ? [version(slug, "2.2.2+26.3", "dimensional-inventories-2.2.2+26.3.jar")]
            : [];
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(list));
      return;
    }
    const f = u.pathname.match(/^\/files\/(.+)$/);
    if (f && JARS[decodeURIComponent(f[1])]) {
      res.end(tamper ? Buffer.from("tampered") : JARS[decodeURIComponent(f[1])]);
      return;
    }
    res.statusCode = 404;
    res.end("{}");
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

function setup(pinsObj, jars = ["fabric-api-0.165.0+26.3.jar"]) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "prepare-mods-"));
  const mods = path.join(dir, "mods");
  fs.mkdirSync(mods);
  for (const j of jars) fs.writeFileSync(path.join(mods, j), "x");
  const pins = path.join(dir, "pins.json");
  fs.writeFileSync(
    pins,
    JSON.stringify(
      pinsObj || {
        requires: ["fabric-api"],
        mods: [
          { slug: "fabricplots", pin: { "26.3": "1.0.2+26.3" } },
          { slug: "dimensional-inventories", pin: { "26.3": "2.2.2+26.3" } },
        ],
      },
    ),
  );
  return { mods, pins };
}

function run({ mods, pins }, extra = []) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [SCRIPT, "--mods-dir", mods, "--mc-version", "26.3", "--pins", pins, ...extra], {
      env: { ...process.env, MODRINTH_API: base },
    });
    let out = "";
    let err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => resolve({ code, out, err }));
  });
}

test("the pinned versions are installed, not the newest ones", async () => {
  tamper = false;
  const s = setup();
  const r = await run(s);
  assert.strictEqual(r.code, 0, r.err);
  assert.ok(fs.existsSync(path.join(s.mods, "fabricplots-1.0.2+26.3.jar")), "the pinned FabricPlots is there");
  assert.ok(!fs.existsSync(path.join(s.mods, "fabricplots-1.1.0+26.3.jar")), "the newer one is not");
  assert.ok(fs.existsSync(path.join(s.mods, "dimensional-inventories-2.2.2+26.3.jar")));
  assert.ok(!r.out.includes("not pinned"), "nothing is reported as unpinned");
});

test("--skip leaves the named mods out and installs the rest", async () => {
  tamper = false;
  const s = setup();
  const r = await run(s, ["--skip", "dimensional-inventories"]);
  assert.strictEqual(r.code, 0, r.err);
  assert.ok(fs.existsSync(path.join(s.mods, "fabricplots-1.0.2+26.3.jar")), "the other mod is installed");
  assert.ok(!fs.existsSync(path.join(s.mods, "dimensional-inventories-2.2.2+26.3.jar")), "the skipped one is not");
  assert.match(r.out, /dimensional-inventories: skipped/);
});

test("without a pin the newest release is used and the run says so", async () => {
  tamper = false;
  const s = setup({ requires: [], mods: [{ slug: "fabricplots", pin: {} }] }, []);
  const r = await run(s);
  assert.strictEqual(r.code, 0, r.err);
  assert.ok(fs.existsSync(path.join(s.mods, "fabricplots-1.1.0+26.3.jar")));
  assert.match(r.out, /not pinned for this Minecraft version/);
});

test("a download whose SHA-512 does not match is not kept", async () => {
  tamper = true;
  const s = setup();
  const r = await run(s);
  tamper = false;
  assert.strictEqual(r.code, 1);
  assert.match(r.err, /SHA-512 of the download does not match/);
  assert.deepStrictEqual(
    fs.readdirSync(s.mods).filter((n) => n.includes("fabricplots")),
    [],
    "no jar and no partial file is left",
  );
});

test("a pinned version that is not published is an error, not a silent upgrade", async () => {
  const s = setup({ requires: [], mods: [{ slug: "fabricplots", pin: { "26.3": "9.9.9+26.3" } }] }, []);
  const r = await run(s);
  assert.strictEqual(r.code, 1);
  assert.match(r.err, /pinned version 9\.9\.9\+26\.3 is not published/);
});

test("a mod that is already installed, or disabled, is left alone", async () => {
  const s = setup(undefined, ["fabric-api-0.165.0+26.3.jar", "FabricPlots-1.0.0.jar"]);
  fs.mkdirSync(path.join(s.mods, "disabled"));
  fs.writeFileSync(path.join(s.mods, "disabled", "dimensional-inventories-1.0.jar"), "x");
  const r = await run(s);
  assert.strictEqual(r.code, 0, r.err);
  assert.match(r.out, /fabricplots: already installed/);
  assert.match(r.out, /dimensional-inventories: already installed/);
  assert.ok(!fs.existsSync(path.join(s.mods, "fabricplots-1.0.2+26.3.jar")), "nothing was downloaded over it");
});

test("a missing Fabric API stops the run before anything is downloaded", async () => {
  const s = setup(undefined, []);
  const r = await run(s);
  assert.strictEqual(r.code, 1);
  assert.match(r.err, /fabric-api is required/);
  assert.deepStrictEqual(fs.readdirSync(s.mods), []);
});

test("a dry run names the versions and downloads nothing", async () => {
  const s = setup();
  const r = await run(s, ["--dry-run"]);
  assert.strictEqual(r.code, 0, r.err);
  assert.match(r.out, /fabricplots: 1\.0\.2\+26\.3/);
  assert.deepStrictEqual(fs.readdirSync(s.mods), ["fabric-api-0.165.0+26.3.jar"]);
});

test("chooseVersion prefers the pin and skips non-release builds otherwise", () => {
  const vs = [
    { version_number: "2.0-beta", version_type: "beta", date_published: "2026-10-05T00:00:00Z" },
    { version_number: "1.0", version_type: "release", date_published: "2026-09-01T00:00:00Z" },
  ];
  assert.strictEqual(chooseVersion(vs, "m", "26.3", {}).version.version_number, "1.0");
  assert.strictEqual(chooseVersion(vs, "m", "26.3", { m: { "26.3": "2.0-beta" } }).pinned, true);
});
