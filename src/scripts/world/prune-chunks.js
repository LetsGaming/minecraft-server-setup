"use strict";

/**
 * prune-chunks.js: delete generated chunks nobody has used, so the next
 * Minecraft version's world generation fills the space.
 *
 * Usage (every mode prints one JSON object per line with --json):
 *   node prune-chunks.js --status
 *   node prune-chunks.js --tile --dimension=<id> --rx=<n> --rz=<n>    draw one region from above
 *   node prune-chunks.js --inspect --plan=<id> --dimension=<id> --cx=<n> --cz=<n>   one chunk, in full
 *   node prune-chunks.js --dimensions             (names and region counts, no chunk is read)
 *   node prune-chunks.js --scan   [--params=<json> | --params-file=<path> | --params-stdin] [--profile] [--no-cache] [--workers=<n>]
 *   node prune-chunks.js --apply  --plan=<id> [--workers=<n>] [--time-budget=<seconds>]
 *   node prune-chunks.js --apply  --plan=<id>
 *   node prune-chunks.js --settings=get
 *   node prune-chunks.js --settings=set --params=<json>
 *
 * --scan only reads (it is safe, and approximate, on a running server) and
 * stores a plan under common/prune/. --apply deletes what a stored plan names
 * and only what a fresh scan still agrees on; it refuses to run while the
 * server is up, because a JVM holds region files open and rewrites them.
 *
 * The caller is responsible for a backup. upgrade-server.js takes one before it
 * calls --apply; run by hand, take one yourself.
 */

const fs = require("fs");
const path = require("path");
const { parseArgs } = require("../update/lib/args");
const { loadVariables } = require("../update/lib/variables");
const { inspectChunk, listDimensions, scanWorld, listScanJobs, newProfile, applyPlan, normalizeParams, touchedKeys } = require("./lib/plan");
const { warmCache, defaultWorkers } = require("./lib/pool");
const { tileFor } = require("./lib/tiles");

const SCRIPTS_DIR = path.resolve(__dirname, "..");
const PRUNE_DIR = path.join(SCRIPTS_DIR, "common", "prune");
const CACHE_DIR = path.join(PRUNE_DIR, "cache");
const TILES_DIR = path.join(PRUNE_DIR, "tiles");
const JOURNAL_FILE = path.join(PRUNE_DIR, "prune-apply.journal");
const DEFAULT_TIME_BUDGET_SECONDS = 45 * 60;
const SETTINGS_FILE = path.join(PRUNE_DIR, "settings.json");
const PLANS_KEPT = 5;
const PLAN_ID_RE = /^[a-f0-9]{16}$/;

const ENGINE = { name: "builtin", version: 1 };

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function fail(code, message, extra = {}) {
  out({ ok: false, code, error: message, ...extra });
  process.exit(1);
}

function ensureDir() {
  fs.mkdirSync(PRUNE_DIR, { recursive: true, mode: 0o700 });
}

function writePrivate(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

const planFile = (id) => path.join(PRUNE_DIR, `${id}.plan.json`);
const mapFile = (id, n) => path.join(PRUNE_DIR, `${id}.map.${n}.json`);

/** Keep only the newest few plans; a plan is a preview, not a record. */
function prunePlans(keepId) {
  let names;
  try {
    names = fs.readdirSync(PRUNE_DIR);
  } catch {
    return;
  }
  const plans = names
    .filter((n) => n.endsWith(".plan.json"))
    .map((n) => ({ id: n.slice(0, -".plan.json".length), mtime: fs.statSync(path.join(PRUNE_DIR, n)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  const keep = new Set(plans.slice(0, PLANS_KEPT).map((p) => p.id));
  keep.add(keepId);
  for (const p of plans) {
    if (keep.has(p.id)) continue;
    for (const n of names) if (n.startsWith(`${p.id}.`)) fs.rmSync(path.join(PRUNE_DIR, n), { force: true });
  }
}

/**
 * A note that an apply started and has not finished. A clean finish removes it; a
 * failed apply leaves it marked "failed", and a process that died leaves it as
 * "applying". Either way the world may be half pruned, so `--status` reports it
 * until the backup is restored or a later apply finishes.
 */
function writeJournal(entry) {
  ensureDir();
  writePrivate(JOURNAL_FILE, JSON.stringify({ version: 1, ...entry }));
}

function readJournal() {
  try {
    const j = JSON.parse(fs.readFileSync(JOURNAL_FILE, "utf8"));
    return j && typeof j.state === "string" ? j : null;
  } catch {
    return null;
  }
}

function readParams(args) {
  const file = args.get("params-file");
  const inline = args.get("params");
  let raw = null;
  try {
    if (args.bool("params-stdin")) raw = JSON.parse(fs.readFileSync(0, "utf8"));
    else if (file) raw = JSON.parse(fs.readFileSync(file, "utf8"));
    else if (inline) raw = JSON.parse(inline);
  } catch {
    fail("params", "The parameters are not valid JSON.");
  }
  return raw;
}

/** No parameters, or an empty object, means the saved settings. */
function scanParams(raw) {
  return raw && typeof raw === "object" && Object.keys(raw).length > 0 ? raw : readSettings();
}

function readSettings() {
  try {
    return normalizeParams(JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8")).params);
  } catch {
    return normalizeParams({});
  }
}

/** The summary a client shows, without the per-region deletion bitmaps. */
function summarize(plan) {
  return {
    id: plan.id,
    createdAt: plan.createdAt,
    params: plan.params,
    warnings: plan.warnings,
    totals: plan.totals,
    dimensions: plan.dimensions.map(({ deletions: _d, dir: _dir, ...rest }) => rest),
  };
}

/** Phase timings in ms, counts, throughput and peak memory for a --profile scan. */
function summarizeProfile(profile, started) {
  const totalMs = Number(process.hrtime.bigint() - started) / 1e6;
  const phases = Object.fromEntries(Object.entries(profile.phases).map(([k, v]) => [k, Math.round(v)]));
  return {
    totalMs: Math.round(totalMs),
    phases,
    counts: profile.counts,
    chunksPerSecond: totalMs > 0 ? Math.round((profile.counts.chunks / totalMs) * 1000) : 0,
    peakRssMb: Math.round(process.resourceUsage().maxRSS / 1024),
  };
}

function serverIsRunning(vars) {
  // The setup suite's own check: RCON, screen session or systemd, whichever answers.
  const { spawnSync } = require("child_process");
  const ops = path.join(SCRIPTS_DIR, "common", "instance_ops.sh");
  // Without the check there is no proof the server is down, so it counts as running.
  if (!fs.existsSync(ops)) return true;
  const r = spawnSync("bash", [ops, "running"], { encoding: "utf8" });
  // 0 up, 1 down, 2 unknown: unknown counts as running, the safe answer here.
  return r.status !== 1;
}

/**
 * Run this same command again under the operation lock. The upgrade job already
 * holds it (MC_OPERATION_LOCK_HELD=1); a hand-run apply takes it here so it
 * cannot overlap a restore, a rollback or an upgrade.
 */
function reenterLocked() {
  const { spawnSync } = require("child_process");
  const common = path.join(SCRIPTS_DIR, "common");
  const script = 'source "$1/load_variables.sh"; source "$1/utils.sh"; acquire_operation_lock prune || exit 75; shift; node "$@"; rc=$?; release_operation_lock; exit $rc';
  const r = spawnSync("bash", ["-c", script, "prune-lock", common, __filename, ...process.argv.slice(2)], { stdio: "inherit" });
  if (r.status === 75) fail("busy", "Another operation is running for this server.");
  process.exit(r.status ?? 1);
}

/** Reads progress out of the cache warm-up as NDJSON lines, at most twice a second. */
function progressReporter(total) {
  const started = Date.now();
  let last = 0;
  let done = 0;
  let chunks = 0;
  return {
    onDone(r) {
      done++;
      chunks += r.chunks ?? 0;
      const now = Date.now();
      if (now - last < 500 && done < total) return;
      last = now;
      const seconds = (now - started) / 1000;
      out({
        phase: "scan",
        done,
        total,
        chunks,
        chunksPerSecond: seconds > 0 ? Math.round(chunks / seconds) : 0,
        etaSeconds: done > 0 ? Math.round((seconds / done) * (total - done)) : null,
      });
    },
  };
}

/** NDJSON progress for the delete, at most twice a second. */
function progressApply() {
  let last = 0;
  return ({ done, total }) => {
    const now = Date.now();
    if (now - last < 500 && done < total) return;
    last = now;
    out({ phase: "prune", done, total });
  };
}

function workersOf(args) {
  const raw = args.get("workers");
  if (raw === null || raw === undefined) return defaultWorkers();
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 && n <= 16 ? n : defaultWorkers();
}

async function main() {
  const args = parseArgs({
    flags: { params: null, "params-file": null, plan: null, settings: null, workers: null, "time-budget": null, dimension: null, cx: null, cz: null, rx: null, rz: null },
    boolFlags: ["status", "scan", "apply", "json", "profile", "no-cache", "dimensions", "params-stdin", "inspect", "tile"],
  });
  const vars = loadVariables(path.join(SCRIPTS_DIR, "common", "variables.txt"), { optional: true });

  if (args.bool("status")) {
    const journal = readJournal();
    out({ ok: true, engine: ENGINE.name, version: ENGINE.version, ...(journal ? { unfinishedApply: journal } : {}) });
    return;
  }

  const settingsMode = args.get("settings");
  if (settingsMode === "get") {
    out({ ok: true, params: readSettings() });
    return;
  }
  if (settingsMode === "set") {
    const params = normalizeParams(readParams(args) ?? {});
    ensureDir();
    // A manual selection belongs to one scan, not to the defaults.
    const { selection: _selection, ...stored } = params;
    writePrivate(SETTINGS_FILE, JSON.stringify({ version: 1, params: stored }, null, 2));
    out({ ok: true, params: normalizeParams(stored) });
    return;
  }

  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) fail("server_path", "SERVER_PATH does not exist.");

  if (args.bool("tile")) {
    const rx = Number(args.get("rx"));
    const rz = Number(args.get("rz"));
    const dimension = args.get("dimension");
    if (!dimension || !Number.isInteger(rx) || !Number.isInteger(rz)) fail("params", "--tile needs --dimension, --rx and --rz.");
    let tile;
    try {
      ensureDir();
      tile = tileFor({ serverPath, dimension, rx, rz, tilesDir: TILES_DIR });
    } catch (err) {
      fail("tile_failed", err.message);
    }
    if (!tile) fail("no_region", "That dimension has no such region.");
    out({ ok: true, tile: tile.relative, cached: tile.cached, chunks: tile.chunks, bytes: tile.bytes });
    return;
  }

  if (args.bool("inspect")) {
    const id = args.get("plan");
    const cx = Number(args.get("cx"));
    const cz = Number(args.get("cz"));
    const dimension = args.get("dimension");
    if (!id || !PLAN_ID_RE.test(id) || !dimension || !Number.isInteger(cx) || !Number.isInteger(cz)) {
      fail("params", "--inspect needs --plan, --dimension, --cx and --cz.");
    }
    let plan;
    try {
      plan = JSON.parse(fs.readFileSync(planFile(id), "utf8"));
    } catch {
      fail("plan_missing", "That plan does not exist any more. Scan again.");
    }
    try {
      out({ ok: true, ...inspectChunk({ serverPath, plan, dimension, cx, cz }) });
    } catch (err) {
      fail(err.code === "dimension" ? "dimension" : "inspect_failed", err.message);
    }
    return;
  }

  if (args.bool("dimensions")) {
    // A directory listing, so the dashboard can offer a choice without reading any chunk.
    try {
      out({ ok: true, dimensions: listDimensions({ serverPath }) });
    } catch (err) {
      fail("scan_failed", err.message);
    }
    return;
  }

  if (args.bool("scan")) {
    let result;
    const profile = args.bool("profile") ? newProfile() : null;
    const started = process.hrtime.bigint();
    try {
      const params = scanParams(readParams(args));
      // --profile measures the plain single-threaded read, so it bypasses the cache and the pool.
      const cacheDir = args.bool("no-cache") || args.bool("profile") ? null : CACHE_DIR;
      if (cacheDir) {
        // Reading is the slow part, so it runs on worker threads and lands in the
        // cache; the decision below then finds every region already read.
        const jobs = listScanJobs({ serverPath, params });
        const progress = progressReporter(jobs.length);
        await warmCache({ jobs, cacheDir, workers: workersOf(args), signals: normalizeParams(params).buildProtection !== "off", onDone: progress.onDone });
      }
      result = scanWorld({ serverPath, params, profile, cacheDir });
    } catch (err) {
      fail("scan_failed", err.message);
    }
    ensureDir();
    const { plan, maps } = result;
    const dims = plan.dimensions;
    writePrivate(planFile(plan.id), JSON.stringify(plan));
    dims.forEach((d, n) => writePrivate(mapFile(plan.id, n), JSON.stringify({ dimension: d.id, ...maps[d.id] })));
    prunePlans(plan.id);
    out({ ok: true, ...summarize(plan), ...(profile ? { profile: summarizeProfile(profile, started) } : {}) });
    return;
  }

  if (args.bool("apply")) {
    if (process.env.MC_OPERATION_LOCK_HELD !== "1") reenterLocked();
    const id = args.get("plan");
    if (!id || !PLAN_ID_RE.test(id)) fail("plan", "A plan id is required.");
    let plan;
    try {
      plan = JSON.parse(fs.readFileSync(planFile(id), "utf8"));
    } catch {
      fail("plan_missing", "That plan does not exist any more. Scan again.");
    }
    if (serverIsRunning(vars)) fail("server_running", "The server must be stopped before chunks are deleted.");
    out({ phase: "prune", msg: "Deleting unused chunks" });
    const budget = Number(args.get("time-budget") ?? DEFAULT_TIME_BUDGET_SECONDS);
    const startedAt = new Date().toISOString();
    writeJournal({ state: "applying", plan: id, startedAt, pid: process.pid });
    try {
      // Regions the plan touches are read fresh (in parallel); the rest may come from the cache.
      const touched = touchedKeys(plan);
      const jobs = listScanJobs({ serverPath, params: plan.params }).filter((j) => touched.has(`${j.dimId}:${j.rx},${j.rz}`));
      await warmCache({ jobs, cacheDir: CACHE_DIR, workers: workersOf(args), force: true, signals: plan.params.buildProtection !== "off" });
      const res = applyPlan({
        serverPath,
        plan,
        cacheDir: CACHE_DIR,
        reread: new Set(),
        timeBudgetMs: Number.isFinite(budget) && budget > 0 ? budget * 1000 : 0,
        onProgress: progressApply(),
      });
      fs.rmSync(JOURNAL_FILE, { force: true });
      out({ ok: true, ...res });
    } catch (err) {
      // Refused before anything was deleted: nothing is half done.
      if (["plan_stale", "plan_invalid"].includes(err.code)) fs.rmSync(JOURNAL_FILE, { force: true });
      else writeJournal({ state: "failed", plan: id, startedAt, error: err.message, code: err.code ?? null });
      fail(["plan_stale", "plan_invalid", "time_budget"].includes(err.code) ? err.code : "apply_failed", err.message);
    }
    return;
  }

  fail("usage", "Use --status, --dimensions, --scan, --apply or --settings.");
}

if (require.main === module) {
  main().catch((err) => fail("failed", err instanceof Error ? err.message : String(err)));
}

module.exports = { summarize };
