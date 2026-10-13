"use strict";

/**
 * Baseline for the chunk-prune scan.
 *
 *   node tests/bench/bench-prune.cjs --chunks=100000            synthetic world
 *   node tests/bench/bench-prune.cjs --world=/path/to/server    real server, read only
 *
 * --workers=<n> reads on n worker threads into a cold cache, then decides: the
 * reported time is read plus decision, as the CLI does it (0 is the same inline).
 * --no-signals turns build protection off, to show what reading the signals costs.
 * --cache scans twice and reports the repeat scan (cache warm).
 * Options: --padding=<longs per chunk> (chunk size, default 400), --keep to
 * leave the synthetic world on disk, --seed=<n>. It only ever calls scan, never
 * apply, so pointing it at a real world is safe. Prints one JSON object.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");

const fx = require("../js/worldFixtures.cjs");
const { scanWorld, listScanJobs, newProfile } = require("../../src/scripts/world/lib/plan.js");
const { warmCache } = require("../../src/scripts/world/lib/pool.js");

const MIN = 20 * 60;

function arg(name, fallback) {
  const hit = process.argv.find((a) => a === `--${name}` || a.startsWith(`--${name}=`));
  if (!hit) return fallback;
  return hit.includes("=") ? hit.slice(name.length + 3) : true;
}

/** Small seeded generator so two runs build the same world. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function buildWorld({ chunks, padding, seed }) {
  const server = fx.makeServer();
  fx.writeLevelDat(server.worldDir, 0, 0);
  const regions = Math.max(1, Math.ceil(chunks / 1024));
  const side = Math.ceil(Math.sqrt(regions));
  const rand = rng(seed);
  let written = 0;
  for (let i = 0; i < regions && written < chunks; i++) {
    const rx = (i % side) - Math.floor(side / 2);
    const rz = Math.floor(i / side) - Math.floor(side / 2);
    const list = [];
    for (let slot = 0; slot < 1024 && written < chunks; slot++, written++) {
      const x = rx * 32 + (slot & 31);
      const z = rz * 32 + (slot >> 5);
      // About 30 % of chunks were ever used, a few of them heavily.
      const used = rand() < 0.3;
      const minutes = used ? Math.floor(rand() * rand() * 600) : 0;
      list.push({ x, z, nbt: fx.chunkModern({ x, z, inhabited: minutes * MIN, padding }) });
    }
    fx.writeRegion(server.regionFile(null, "region", rx, rz), rx, rz, list);
  }
  return server;
}

async function main() {
  const benchParams = arg("no-signals", false) ? { buildProtection: "off" } : {};
  const worldArg = arg("world", null);
  const chunks = Number(arg("chunks", 100000));
  const padding = Number(arg("padding", 400));
  const seed = Number(arg("seed", 1));

  let server = null;
  let serverPath = worldArg;
  let generateMs = 0;
  if (!serverPath) {
    const t0 = Date.now();
    server = buildWorld({ chunks, padding, seed });
    generateMs = Date.now() - t0;
    serverPath = server.dir;
  }

  const workers = arg("workers", null);
  const cacheDir = arg("cache", false) || workers !== null ? fs.mkdtempSync(path.join(os.tmpdir(), "prune-bench-cache-")) : null;
  const runScan = async () => {
    const profile = newProfile();
    const t0 = process.hrtime.bigint();
    if (workers !== null) {
      await warmCache({ jobs: listScanJobs({ serverPath, params: benchParams }), cacheDir, workers: Number(workers), signals: benchParams.buildProtection !== "off" });
      if (arg("cache", false)) profile.phases.warm = Number(process.hrtime.bigint() - t0) / 1e6;
    }
    const { plan } = scanWorld({ serverPath, params: benchParams, profile, cacheDir });
    return { profile, plan, totalMs: Number(process.hrtime.bigint() - t0) / 1e6 };
  };
  // With --cache the first scan fills the cache and the second is the repeat scan that is reported.
  if (arg("cache", false)) await runScan();
  const { profile, plan, totalMs } = await runScan();

  const report = {
    source: worldArg ? "real" : "synthetic",
    node: process.version,
    cpus: os.cpus().length,
    workers: workers === null ? "none" : Number(workers),
    generateMs,
    scanMs: Math.round(totalMs),
    phasesMs: Object.fromEntries(Object.entries(profile.phases).map(([k, v]) => [k, Math.round(v)])),
    counts: profile.counts,
    chunksPerSecond: Math.round((plan.totals.chunks / totalMs) * 1000),
    peakRssMb: Math.round(process.resourceUsage().maxRSS / 1024),
    totals: plan.totals,
  };
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");

  if (cacheDir) fs.rmSync(cacheDir, { recursive: true, force: true });
  if (server && !arg("keep", false)) server.cleanup();
  else if (server) process.stderr.write(`kept ${path.resolve(server.dir)}\n`);
}

main();

