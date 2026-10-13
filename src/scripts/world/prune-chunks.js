"use strict";

/**
 * prune-chunks.js: delete generated chunks nobody has used, so the next
 * Minecraft version's world generation fills the space.
 *
 * Usage (every mode prints one JSON object per line with --json):
 *   node prune-chunks.js --status
 *   node prune-chunks.js --scan   [--params=<json> | --params-file=<path>]
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
const { scanWorld, applyPlan, normalizeParams } = require("./lib/plan");

const SCRIPTS_DIR = path.resolve(__dirname, "..");
const PRUNE_DIR = path.join(SCRIPTS_DIR, "common", "prune");
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

function readParams(args) {
  const file = args.get("params-file");
  const inline = args.get("params");
  let raw = null;
  try {
    if (file) raw = JSON.parse(fs.readFileSync(file, "utf8"));
    else if (inline) raw = JSON.parse(inline);
  } catch {
    fail("params", "The parameters are not valid JSON.");
  }
  return raw;
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

function serverIsRunning(vars) {
  // The setup suite's own check: RCON, screen session or systemd, whichever answers.
  const { spawnSync } = require("child_process");
  const ops = path.join(SCRIPTS_DIR, "common", "instance_ops.sh");
  if (!fs.existsSync(ops)) return false;
  const r = spawnSync("bash", [ops, "running"], { encoding: "utf8" });
  // 0 up, 1 down, 2 unknown: unknown counts as running, the safe answer here.
  return r.status !== 1;
}

function main() {
  const args = parseArgs({
    flags: { params: null, "params-file": null, plan: null, settings: null },
    boolFlags: ["status", "scan", "apply", "json"],
  });
  const vars = loadVariables(path.join(SCRIPTS_DIR, "common", "variables.txt"), { optional: true });

  if (args.bool("status")) {
    out({ ok: true, engine: ENGINE.name, version: ENGINE.version });
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
    writePrivate(SETTINGS_FILE, JSON.stringify({ version: 1, params }, null, 2));
    out({ ok: true, params });
    return;
  }

  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) fail("server_path", "SERVER_PATH does not exist.");

  if (args.bool("scan")) {
    let result;
    try {
      result = scanWorld({ serverPath, params: readParams(args) ?? readSettings() });
    } catch (err) {
      fail("scan_failed", err.message);
    }
    ensureDir();
    const { plan, maps } = result;
    const dims = plan.dimensions;
    writePrivate(planFile(plan.id), JSON.stringify(plan));
    dims.forEach((d, n) => writePrivate(mapFile(plan.id, n), JSON.stringify({ dimension: d.id, ...maps[d.id] })));
    prunePlans(plan.id);
    out({ ok: true, ...summarize(plan) });
    return;
  }

  if (args.bool("apply")) {
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
    try {
      const res = applyPlan({ serverPath, plan });
      out({ ok: true, ...res });
    } catch (err) {
      fail(err.code === "plan_stale" ? "plan_stale" : "apply_failed", err.message);
    }
    return;
  }

  fail("usage", "Use --status, --scan, --apply or --settings.");
}

if (require.main === module) {
  main();
}

module.exports = { summarize };
