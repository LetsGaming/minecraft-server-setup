const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const INSTALLER = path.resolve(__dirname, "..", "..", "src", "setup", "management", "install_api_server.js");
const { install, inspect, releaseUrl, readPin, replaceContents, MARKER } = require(INSTALLER);

const REPO = "LetsGaming/minecraft-server-api";
const quiet = () => {};

/** A release tarball shaped like the wrapper's: mc-api-server-<v>/{package.json, lockfile, index.js, dist/}. */
function makeTarball(root, version, { withDist = true, pkgVersion = version } = {}) {
  const src = path.join(root, `src-${version}-${crypto.randomUUID()}`);
  const top = path.join(src, `mc-api-server-${version}`);
  fs.mkdirSync(path.join(top, "dist"), { recursive: true });
  const pkg = { name: "mc-api-server", version: pkgVersion, type: "module" };
  fs.writeFileSync(path.join(top, "package.json"), JSON.stringify(pkg));
  fs.writeFileSync(
    path.join(top, "package-lock.json"),
    JSON.stringify({ name: "mc-api-server", version: pkgVersion, lockfileVersion: 3, requires: true, packages: { "": pkg } }),
  );
  fs.writeFileSync(path.join(top, "index.js"), 'import "./dist/index.js";\n');
  if (withDist) fs.writeFileSync(path.join(top, "dist", "index.js"), `// ${version}\n`);
  const file = path.join(root, `mc-api-server-${version}-${crypto.randomUUID()}.tar.gz`);
  const res = spawnSync("tar", ["-czf", file, "-C", src, `mc-api-server-${version}`]);
  assert.equal(res.status, 0, String(res.stderr));
  return { file, sha256: crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex") };
}

function scratch(fn) {
  return async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-apiserver-"));
    try {
      await fn(root, path.join(root, "services", "api-server"));
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  };
}

test("the pin in the repo is well formed and names a GitHub release asset", () => {
  const pin = readPin();
  assert.equal(pin.repository, REPO);
  assert.equal(
    releaseUrl(pin, ""),
    `https://github.com/${REPO}/releases/download/v${pin.version}/mc-api-server-${pin.version}.tar.gz`,
  );
});

test("a pin pasted from GitHub's release page (sha256:<HEX>) is accepted", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-pin-"));
  try {
    const file = path.join(dir, "pin.json");
    fs.writeFileSync(file, JSON.stringify({ repository: REPO, version: "4.1.0", sha256: `sha256:${"AB".repeat(32)}` }));
    assert.equal(readPin(file).sha256, "ab".repeat(32));
    fs.writeFileSync(file, JSON.stringify({ repository: REPO, version: "4.1.0", sha256: "sha256:abc" }));
    assert.throws(() => readPin(file), /64 hex characters/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a folder without the wrapper is missing; a copy without a release marker is unmanaged", scratch(async (root, dir) => {
  const pin = { repository: REPO, version: "4.1.0", sha256: "" };
  assert.equal(inspect(dir, pin).state, "missing");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "index.js"), "");
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ version: "4.0.0" }));
  assert.deepEqual(inspect(dir, pin), { state: "unmanaged", installed: "4.0.0", pinned: "4.1.0" });
}));

test("installs a verified tarball and records the release", scratch(async (root, dir) => {
  const t = makeTarball(root, "4.1.0");
  const pin = { repository: REPO, version: "4.1.0", sha256: t.sha256 };
  const r = await install({ dir, pin, tarball: t.file, log: quiet });
  assert.equal(r.state, "missing");
  assert.equal(r.changed, true);
  assert.equal(fs.readFileSync(path.join(dir, "dist", "index.js"), "utf8"), "// 4.1.0\n");
  const marker = JSON.parse(fs.readFileSync(path.join(dir, MARKER), "utf8"));
  assert.equal(marker.version, "4.1.0");
  assert.equal(marker.sha256, t.sha256);
  assert.equal(inspect(dir, pin).state, "current");
  // No staging folder is left next to the install.
  assert.deepEqual(fs.readdirSync(path.dirname(dir)), ["api-server"]);

  const again = await install({ dir, pin, tarball: t.file, log: quiet });
  assert.equal(again.changed, false);
}));

test("an upgrade replaces the code, drops stale files and keeps config and logs", scratch(async (root, dir) => {
  const old = makeTarball(root, "4.0.9");
  await install({ dir, pin: { repository: REPO, version: "4.0.9", sha256: old.sha256 }, tarball: old.file, log: quiet });
  fs.writeFileSync(path.join(dir, "api-server-config.json"), '{"apiKey":"keep"}');
  fs.mkdirSync(path.join(dir, "logs"));
  fs.writeFileSync(path.join(dir, "logs", "api-server.log"), "old log");
  fs.writeFileSync(path.join(dir, "dist", "gone.js"), "stale");

  const t = makeTarball(root, "4.1.0");
  const pin = { repository: REPO, version: "4.1.0", sha256: t.sha256 };
  assert.equal(inspect(dir, pin).state, "outdated");
  const r = await install({ dir, pin, tarball: t.file, log: quiet });
  assert.equal(r.installed, "4.0.9");
  assert.equal(fs.readFileSync(path.join(dir, "dist", "index.js"), "utf8"), "// 4.1.0\n");
  assert.equal(fs.existsSync(path.join(dir, "dist", "gone.js")), false);
  assert.equal(fs.readFileSync(path.join(dir, "api-server-config.json"), "utf8"), '{"apiKey":"keep"}');
  assert.equal(fs.readFileSync(path.join(dir, "logs", "api-server.log"), "utf8"), "old log");
}));

test("a sha256 mismatch fails before anything in the install changes", scratch(async (root, dir) => {
  const good = makeTarball(root, "4.0.9");
  await install({ dir, pin: { repository: REPO, version: "4.0.9", sha256: good.sha256 }, tarball: good.file, log: quiet });
  const bad = makeTarball(root, "4.1.0");
  await assert.rejects(
    install({ dir, pin: { repository: REPO, version: "4.1.0", sha256: "0".repeat(64) }, tarball: bad.file, log: quiet }),
    /sha256 mismatch.*not the digest of the \.sha256 file/,
  );
  assert.equal(fs.readFileSync(path.join(dir, "dist", "index.js"), "utf8"), "// 4.0.9\n");
  assert.deepEqual(fs.readdirSync(path.dirname(dir)), ["api-server"]);
}));

test("a pin without a sha256 is refused unless verification is turned off", scratch(async (root, dir) => {
  const t = makeTarball(root, "4.1.0");
  const pin = { repository: REPO, version: "4.1.0", sha256: "" };
  await assert.rejects(install({ dir, pin, tarball: t.file, log: quiet }), /without a sha256/);
  assert.equal(fs.existsSync(dir), false);
  const lines = [];
  const r = await install({ dir, pin, tarball: t.file, verify: false, log: (m) => lines.push(m) });
  assert.equal(r.changed, true);
  assert.match(lines.at(-1), /now runs release 4\.1\.0\.$/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, MARKER), "utf8")).sha256, t.sha256);
}));

test("a tarball that is not a built release, or holds another version, is refused", scratch(async (root, dir) => {
  const unbuilt = makeTarball(root, "4.1.0", { withDist: false });
  await assert.rejects(
    install({ dir, pin: { repository: REPO, version: "4.1.0", sha256: unbuilt.sha256 }, tarball: unbuilt.file, log: quiet }),
    /not a built mc-api-server release/,
  );
  const other = makeTarball(root, "4.1.0", { pkgVersion: "4.0.0" });
  const lines = [];
  await install({ dir: path.join(root, "own"), pin: { repository: REPO, version: "4.1.0", sha256: "" }, tarball: other.file, verify: false, log: (m) => lines.push(m) });
  assert.match(lines.at(-1), /now runs release 4\.0\.0\.$/);
  await assert.rejects(
    install({ dir, pin: { repository: REPO, version: "4.1.0", sha256: other.sha256 }, tarball: other.file, log: quiet }),
    /holds version 4\.0\.0/,
  );
  assert.equal(fs.existsSync(path.join(dir, "index.js")), false);
}));

test("downloads the release asset from the release base and verifies it", scratch(async (root, dir) => {
  const t = makeTarball(root, "4.1.0");
  const asked = [];
  const server = http.createServer((req, res) => {
    asked.push(req.url);
    if (req.url === "/v4.1.0/mc-api-server-4.1.0.tar.gz") {
      res.writeHead(200, { "content-type": "application/gzip" });
      res.end(fs.readFileSync(t.file));
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const prev = process.env.MC_API_SERVER_RELEASE_BASE;
  process.env.MC_API_SERVER_RELEASE_BASE = `http://127.0.0.1:${server.address().port}/`;
  try {
    await install({ dir, pin: { repository: REPO, version: "4.1.0", sha256: t.sha256 }, log: quiet });
    assert.deepEqual(asked, ["/v4.1.0/mc-api-server-4.1.0.tar.gz"]);
    assert.equal(inspect(dir, { version: "4.1.0", sha256: t.sha256 }).state, "current");
    await assert.rejects(
      install({ dir: path.join(root, "other"), pin: { repository: REPO, version: "9.9.9", sha256: t.sha256 }, log: quiet }),
      /answered 404/,
    );
  } finally {
    if (prev === undefined) delete process.env.MC_API_SERVER_RELEASE_BASE;
    else process.env.MC_API_SERVER_RELEASE_BASE = prev;
    server.close();
  }
}));

test("--check prints one line and changes nothing", scratch(async (root, dir) => {
  const res = spawnSync(process.execPath, [INSTALLER, "--dir", dir, "--check"], { encoding: "utf8" });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout.trim(), `state=missing installed=- pinned=${readPin().version}`);
  assert.equal(fs.existsSync(dir), false);
}));

test("replacing the install swaps whole folders: preserved files carry over and no .old is left", scratch(async (root, dir) => {
  fs.mkdirSync(path.join(dir, "logs"), { recursive: true });
  fs.writeFileSync(path.join(dir, "index.js"), "old");
  fs.writeFileSync(path.join(dir, "stale.js"), "stale");
  fs.writeFileSync(path.join(dir, ".env"), "KEEP=1");
  fs.writeFileSync(path.join(dir, "logs", "a.log"), "log");
  const fresh = path.join(root, "services", ".api-server-staging-x");
  fs.mkdirSync(fresh, { recursive: true });
  fs.writeFileSync(path.join(fresh, "index.js"), "new");
  fs.writeFileSync(path.join(fresh, ".env"), "KEEP=0");

  replaceContents(dir, fresh);

  assert.equal(fs.readFileSync(path.join(dir, "index.js"), "utf8"), "new");
  assert.equal(fs.existsSync(path.join(dir, "stale.js")), false);
  assert.equal(fs.readFileSync(path.join(dir, ".env"), "utf8"), "KEEP=1");
  assert.equal(fs.readFileSync(path.join(dir, "logs", "a.log"), "utf8"), "log");
  assert.deepEqual(fs.readdirSync(path.dirname(dir)), ["api-server"]);
}));

test("a failure while preparing the swap leaves the old install exactly as it was", scratch(async (root, dir) => {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "index.js"), "old");
  fs.writeFileSync(path.join(dir, ".env"), "KEEP=1");
  const notAFolder = path.join(root, "services", "staging-is-a-file");
  fs.writeFileSync(notAFolder, "x");

  assert.throws(() => replaceContents(dir, notAFolder));

  assert.equal(fs.readFileSync(path.join(dir, "index.js"), "utf8"), "old");
  assert.equal(fs.readFileSync(path.join(dir, ".env"), "utf8"), "KEEP=1");
  assert.equal(fs.existsSync(`${dir}.old`), false);
}));

test("a first install into a missing folder just moves the staging folder into place", scratch(async (root, dir) => {
  const fresh = path.join(root, "services", ".api-server-staging-y");
  fs.mkdirSync(fresh, { recursive: true });
  fs.writeFileSync(path.join(fresh, "index.js"), "new");
  replaceContents(dir, fresh);
  assert.equal(fs.readFileSync(path.join(dir, "index.js"), "utf8"), "new");
  assert.equal(fs.existsSync(fresh), false);
}));
