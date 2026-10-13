const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const fx = require("./worldFixtures.cjs");

const SRC = path.resolve(__dirname, "..", "..", "src", "scripts");
const MIN = 20 * 60;
const LEAN = { thresholdMinutes: 5, bufferChunks: 0, spawnRadiusChunks: 0, playerRadiusChunks: 0 };

/** A scripts tree with the prune script and a server with a small world. */
function setup() {
  const server = fx.makeServer();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-prunecli-"));
  const scripts = path.join(root, "scripts");
  fs.mkdirSync(path.join(scripts, "common"), { recursive: true });
  fs.cpSync(path.join(SRC, "world"), path.join(scripts, "world"), { recursive: true });
  fs.mkdirSync(path.join(scripts, "update"), { recursive: true });
  fs.cpSync(path.join(SRC, "update", "lib"), path.join(scripts, "update", "lib"), { recursive: true });
  // The real check is a bash script; "running" answers 1 (down) here.
  fs.writeFileSync(path.join(scripts, "common", "instance_ops.sh"), '#!/bin/bash\n[ "$1" = running ] && exit 1\nexit 0\n');
  fs.writeFileSync(path.join(scripts, "common", "variables.txt"), `USER="t"\nINSTANCE_NAME="inst"\nSERVER_PATH="${server.dir}"\n`);

  fx.writeLevelDat(server.worldDir, 100_000, 100_000);
  const chunks = [0, 1, 2, 3].map((i) => ({
    x: i,
    z: 0,
    nbt: fx.chunkModern({ x: i, z: 0, inhabited: (i === 2 ? 60 : 0) * MIN }),
  }));
  for (const folder of ["region", "entities", "poi"]) {
    fx.writeRegion(server.regionFile(null, folder, 0, 0), 0, 0, chunks);
  }

  const run = (args) => {
    const res = spawnSync(process.execPath, [path.join(scripts, "world", "prune-chunks.js"), ...args], {
      encoding: "utf8",
      cwd: scripts,
      env: { ...process.env, MC_OPERATION_LOCK_HELD: "1" },
    });
    const lines = (res.stdout ?? "").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
    return { code: res.status, lines, last: lines.at(-1), stderr: res.stderr };
  };
  return { server, scripts, run, cleanup: () => { server.cleanup(); fs.rmSync(root, { recursive: true, force: true }); } };
}

function withSetup(fn) {
  return () => {
    const s = setup();
    try {
      fn(s);
    } finally {
      s.cleanup();
    }
  };
}

test("--status names the engine", withSetup((s) => {
  const r = s.run(["--status"]);
  assert.equal(r.code, 0);
  assert.deepEqual(r.last, { ok: true, engine: "builtin", version: 1 });
}));

test("--scan stores a plan and a map and reports a summary without the bitmaps", withSetup((s) => {
  const r = s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.last.ok, true);
  assert.match(r.last.id, /^[a-f0-9]{16}$/);
  assert.equal(r.last.totals.delete, 3);
  assert.equal(r.last.dimensions[0].id, "overworld");
  assert.equal("deletions" in r.last.dimensions[0], false);
  const dir = path.join(s.scripts, "common", "prune");
  assert.ok(fs.existsSync(path.join(dir, `${r.last.id}.plan.json`)));
  const map = JSON.parse(fs.readFileSync(path.join(dir, `${r.last.id}.map.0.json`), "utf8"));
  assert.equal(map.dimension, "overworld");
  assert.ok(map.regions["r.0.0"].cell);
}));

test("--scan changes nothing in the world", withSetup((s) => {
  const file = s.server.regionFile(null, "region", 0, 0);
  const before = fs.readFileSync(file);
  s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]);
  assert.deepEqual(fs.readFileSync(file), before);
}));

test("--apply deletes what the plan named", withSetup((s) => {
  const { last: scan } = s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]);
  const r = s.run(["--apply", `--plan=${scan.id}`]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.last.ok, true);
  assert.equal(r.last.deletedChunks, 3);
  assert.equal(r.lines[0].phase, "prune");
  const after = s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]);
  assert.equal(after.last.totals.delete, 0);
}));

test("--apply refuses an unknown or malformed plan", withSetup((s) => {
  const missing = s.run(["--apply", "--plan=0123456789abcdef"]);
  assert.equal(missing.code, 1);
  assert.equal(missing.last.code, "plan_missing");
  const bad = s.run(["--apply", "--plan=../etc"]);
  assert.equal(bad.last.code, "plan");
  const none = s.run(["--apply"]);
  assert.equal(none.last.code, "plan");
}));

test("--apply reports a plan that went stale and deletes nothing", withSetup((s) => {
  const { last: scan } = s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]);
  // Every chunk gets busy before the server stops.
  fx.writeRegion(
    s.server.regionFile(null, "region", 0, 0),
    0,
    0,
    [0, 1, 2, 3].map((i) => ({ x: i, z: 0, nbt: fx.chunkModern({ x: i, z: 0, inhabited: 90 * MIN }) })),
  );
  const r = s.run(["--apply", `--plan=${scan.id}`]);
  assert.equal(r.code, 1);
  assert.equal(r.last.code, "plan_stale");
}));

test("settings round-trip, normalised, and default to the built-in parameters", withSetup((s) => {
  const first = s.run(["--settings=get"]);
  assert.equal(first.last.params.thresholdMinutes, 5);
  const set = s.run(["--settings=set", `--params=${JSON.stringify({ thresholdMinutes: 12, bufferChunks: 999 })}`]);
  assert.equal(set.last.params.thresholdMinutes, 12);
  assert.equal(set.last.params.bufferChunks, 32);
  assert.equal(s.run(["--settings=get"]).last.params.thresholdMinutes, 12);
}));

test("a scan with no parameters uses the saved settings", withSetup((s) => {
  s.run(["--settings=set", `--params=${JSON.stringify(LEAN)}`]);
  const r = s.run(["--scan"]);
  assert.equal(r.last.params.bufferChunks, 0);
  assert.equal(r.last.totals.delete, 3);
}));

test("only the newest few plans are kept", withSetup((s) => {
  for (let t = 1; t <= 8; t++) s.run(["--scan", `--params=${JSON.stringify({ ...LEAN, thresholdMinutes: t + 100 })}`]);
  const plans = fs.readdirSync(path.join(s.scripts, "common", "prune")).filter((n) => n.endsWith(".plan.json"));
  assert.ok(plans.length <= 5, String(plans.length));
}));

test("invalid parameters are an error, not a silent default", withSetup((s) => {
  const r = s.run(["--scan", "--params={not json"]);
  assert.equal(r.code, 1);
  assert.equal(r.last.code, "params");
}));

test("--apply refuses when the server check is missing", withSetup((s) => {
  const { last: scan } = s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]);
  fs.rmSync(path.join(s.scripts, "common", "instance_ops.sh"));
  const r = s.run(["--apply", `--plan=${scan.id}`]);
  assert.equal(r.code, 1);
  assert.equal(r.last.code, "server_running");
}));

test("--scan with an empty parameter object uses the saved settings", withSetup((s) => {
  s.run(["--settings=set", `--params=${JSON.stringify({ thresholdMinutes: 1000, bufferChunks: 0 })}`]);
  const empty = s.run(["--scan", "--params={}"]);
  assert.equal(empty.last.params.thresholdMinutes, 1000);
  assert.equal(empty.last.totals.delete, 4);
}));

test("--scan --profile reports phase timings and counts", withSetup((s) => {
  const r = s.run(["--scan", "--profile", `--params=${JSON.stringify(LEAN)}`]);
  assert.equal(r.last.ok, true);
  const p = r.last.profile;
  assert.equal(p.counts.chunks, 4);
  assert.equal(p.counts.regions, 1);
  for (const phase of ["read", "inflate", "nbt", "classify", "assemble"]) assert.ok(phase in p.phases, phase);
  assert.ok(p.peakRssMb > 0);
  assert.equal("profile" in s.run(["--scan", `--params=${JSON.stringify(LEAN)}`]).last, false);
}));
