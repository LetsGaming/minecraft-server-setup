const test = require("node:test");
const assert = require("node:assert/strict");
const { runUpgrade, startAndWatch } = require("../../src/scripts/update/upgrade-server.js");

const OK = { code: 0, stdout: "", stderr: "" };
const FAIL = { code: 1, stdout: "", stderr: "boom" };
const json = (...objs) => objs.map((o) => JSON.stringify(o)).join("\n") + "\n";

const PLAN = { ok: true, current: "1.21.1", target: "1.21.5", unavailable: [], java: { required: "21", installed: true } };

/**
 * A scripted world: `startResults` decides what each start produces, in order.
 * "ready" writes the Done line, "crash" writes the give-up event, "hang" writes nothing.
 */
function world({ plan = PLAN, startResults = ["ready"], apply, backup, restore, stop, toggle } = {}) {
  let t = 1_000_000;
  const calls = [];
  const emitted = [];
  let logText = "";
  let eventsText = "";
  const archives = [];
  let versionsFile = '{"gameVersion":"1.21.1"}';
  const starts = [...startResults];

  const deps = {
    emitted,
    calls,
    now: () => t,
    sleep: (s) => {
      t += s * 1000;
    },
    emit: (o) => emitted.push(o),
    log: { size: () => logText.length, since: (o) => logText.slice(o) },
    events: { size: () => eventsText.length, since: (o) => eventsText.slice(o) },
    listArchives: () => [...archives],
    archivePath: (n) => `/b/archives/update/${n}`,
    readVersionsFile: () => versionsFile,
    writeVersionsFile: (x) => {
      versionsFile = x;
      calls.push(["versions", x]);
    },
    get versionsFile() {
      return versionsFile;
    },
    run(kind, args) {
      calls.push([kind, ...args]);
      if (kind === "update" && args.includes("--plan")) return { ...OK, stdout: json(plan) };
      if (kind === "update" && args.includes("--apply")) {
        return apply ?? { ...OK, stdout: json({ phase: "jar", msg: "j" }, { ok: true, version: "1.21.5" }) };
      }
      if (kind === "backup") {
        if (backup) return backup;
        archives.push("minecraft_backup_NEW.tar.zst");
        return OK;
      }
      if (kind === "restore") return restore ?? OK;
      if (kind === "toggle") return toggle ?? OK;
      if (kind === "ops" && args[0] === "stop") return stop ?? OK;
      if (kind === "ops" && args[0] === "start") {
        const next = starts.shift() ?? "ready";
        if (next === "ready") logText += '[12:00:01] [Server thread/INFO]: Done (4.2s)! For help, type "help"\n';
        if (next === "crash") eventsText += '{"ts":1,"type":"crash_loop_gave_up"}\n';
        return OK;
      }
      return OK;
    },
  };
  return deps;
}

const OPTS = { version: "1.21.5", expectUnavailable: null, countdown: 0, startTimeout: 60, prunePlan: null };
const phases = (w) => w.emitted.filter((e) => e.phase).map((e) => `${e.phase}:${e.status}`);
const result = (w) => w.emitted.at(-1);
const count = (w, kind, first) => w.calls.filter((c) => c[0] === kind && (first === undefined || c[1] === first)).length;

test("a clean upgrade stops, backs up, installs, starts and reports success", () => {
  const w = world();
  const r = runUpgrade(w, OPTS);
  assert.equal(r.ok, true);
  assert.equal(r.branch, "clean");
  assert.equal(r.archive, "minecraft_backup_NEW.tar.zst");
  const order = w.calls.map((c) => `${c[0]}:${c[1] ?? ""}`).filter((c) => /^(ops:(stop|start)|backup|update)/.test(c));
  assert.deepEqual(order.slice(0, 5), ["update:1.21.5", "ops:stop", "backup:--archive", "update:1.21.5", "ops:start"]);
  assert.equal(result(w).type, "result");
});

test("the backup must succeed before anything is changed, and the server is started again", () => {
  const w = world({ backup: FAIL });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.ok, false);
  assert.equal(r.reason, "backup_failed");
  assert.equal(w.calls.some((c) => c[0] === "update" && c.includes("--apply")), false, "no install ran");
  assert.equal(count(w, "ops", "start"), 1, "the server was restarted");
});

test("a server that will not stop aborts before the backup", () => {
  const w = world({ stop: FAIL });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.reason, "stop_failed");
  assert.equal(count(w, "backup"), 0);
});

test("unavailable mods are kept for the first start; if it works they are reported as on an old build", () => {
  const w = world({ plan: { ...PLAN, unavailable: ["sodium"] } });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.branch, "clean");
  assert.deepEqual(r.keptOnOldBuild, ["sodium"]);
  assert.equal(count(w, "toggle"), 0, "nothing was disabled");
});

test("a crash loop disables exactly the unavailable mods and tries again", () => {
  const w = world({ plan: { ...PLAN, unavailable: ["sodium", "lithium"] }, startResults: ["crash", "ready"] });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.ok, true);
  assert.equal(r.branch, "mods_disabled");
  assert.deepEqual(r.disabled, ["lithium", "sodium"]);
  assert.deepEqual(
    w.calls.filter((c) => c[0] === "toggle").map((c) => c[1]),
    ["lithium", "sodium"],
  );
  assert.equal(count(w, "ops", "halt"), 1, "the crash-looping service was stopped");
});

test("a hang past the timeout counts as a failed start", () => {
  const w = world({ plan: { ...PLAN, unavailable: ["sodium"] }, startResults: ["hang", "ready"] });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.branch, "mods_disabled");
});

test("two failed starts roll back to this job's own backup and restore the version record", () => {
  const w = world({ plan: { ...PLAN, unavailable: ["sodium"] }, startResults: ["crash", "crash", "ready"] });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.ok, false);
  assert.equal(r.rolledBack, true);
  assert.equal(r.previousVersionRunning, true);
  const restore = w.calls.find((c) => c[0] === "restore");
  assert.deepEqual(restore, ["restore", "--y", "--archive", "--file", "/b/archives/update/minecraft_backup_NEW.tar.zst"]);
  assert.equal(w.versionsFile, '{"gameVersion":"1.21.1"}');
});

test("with no unavailable mods a single failed start goes straight to the rollback", () => {
  const w = world({ startResults: ["crash", "ready"] });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.rolledBack, true);
  assert.equal(count(w, "toggle"), 0);
});

test("a failed install rolls back", () => {
  const w = world({ apply: { code: 1, stdout: json({ ok: false, error: "no jar" }), stderr: "" } });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.rolledBack, true);
  assert.equal(r.reason, "apply_failed");
});

test("a failed restore is reported loudly and nothing is started on top of it", () => {
  const w = world({ startResults: ["crash"], restore: FAIL });
  const r = runUpgrade(w, OPTS);
  assert.equal(r.reason, "rollback_failed");
  assert.equal(r.rolledBack, false);
  assert.equal(count(w, "ops", "start"), 1, "only the first start happened");
});

test("the mod set the user saw must be the one that runs", () => {
  const w = world({ plan: { ...PLAN, unavailable: ["sodium"] } });
  const r = runUpgrade(w, { ...OPTS, expectUnavailable: ["lithium"] });
  assert.equal(r.reason, "mods_changed");
  assert.equal(count(w, "ops", "stop"), 0, "nothing was touched");
});

const PLAN_ID = "0123456789abcdef";
const pruneWorld = (prune) => {
  const w = world();
  const orig = w.run;
  w.run = (kind, args) => {
    if (kind !== "prune") return orig(kind, args);
    w.calls.push([kind, ...args]);
    return prune(args);
  };
  return w;
};
const PRUNE_OK = { code: 0, stdout: json({ ok: true, deletedChunks: 120, bytesFreed: 4096 }), stderr: "" };

test("a failed prune rolls the whole upgrade back", () => {
  const w = pruneWorld(() => FAIL);
  const r = runUpgrade(w, { ...OPTS, prunePlan: PLAN_ID });
  assert.equal(r.reason, "prune_failed");
  assert.equal(r.rolledBack, true);
});

test("a prune plan that went stale rolls back with its own reason", () => {
  const w = pruneWorld(() => ({ code: 1, stdout: json({ ok: false, code: "plan_stale", error: "x" }), stderr: "" }));
  const r = runUpgrade(w, { ...OPTS, prunePlan: PLAN_ID });
  assert.equal(r.reason, "prune_stale");
});

test("the prune runs after the install and before the first start, and is reported", () => {
  const w = pruneWorld(() => PRUNE_OK);
  const r = runUpgrade(w, { ...OPTS, prunePlan: PLAN_ID });
  assert.equal(r.ok, true);
  assert.equal(r.prunedChunks, 120);
  assert.equal(r.bytesFreed, 4096);
  const order = w.calls.map((c) => c[0] + ":" + (c.includes("--apply") ? "apply" : c[1] ?? ""));
  const apply = order.indexOf("update:apply");
  const prune = order.indexOf("prune:apply");
  const start = order.indexOf("ops:start");
  assert.ok(apply >= 0 && prune > apply && start > prune, order.join(" "));
  assert.deepEqual(w.calls.find((c) => c[0] === "prune"), ["prune", "--apply", "--plan=" + PLAN_ID, "--time-budget=2700", "--json"]);
});

test("a prune-only job has no install and no version, and still has the backup and the fallback", () => {
  const w = pruneWorld(() => PRUNE_OK);
  const r = runUpgrade(w, { ...OPTS, version: null, prunePlan: PLAN_ID });
  assert.equal(r.ok, true);
  assert.equal(r.target, null);
  assert.equal(w.calls.some((c) => c[0] === "update"), false, "the update script is never run");
  assert.equal(count(w, "backup"), 1);
  assert.equal(count(w, "prune"), 1);
});

test("a prune-only job whose start fails restores the backup", () => {
  const w = world({ startResults: ["crash", "ready"] });
  const orig = w.run;
  w.run = (kind, args) => {
    if (kind !== "prune") return orig(kind, args);
    w.calls.push([kind, ...args]);
    return PRUNE_OK;
  };
  const r = runUpgrade(w, { ...OPTS, version: null, prunePlan: PLAN_ID });
  assert.equal(r.rolledBack, true);
  assert.equal(count(w, "restore"), 1);
});

test("progress lines are numbered and the last one is the result", () => {
  const w = world();
  runUpgrade(w, OPTS);
  const seqs = w.emitted.map((e) => e.seq);
  assert.deepEqual(seqs, seqs.map((_, i) => i + 1));
  assert.ok(phases(w).includes("backup:done"));
});

test("startAndWatch reads a rotated log from the start", () => {
  const w = world();
  let size = 500;
  let text = "";
  w.log = { size: () => size, since: (o) => text.slice(o) };
  const orig = w.run;
  w.run = (kind, args) => {
    if (kind === "ops" && args[0] === "start") {
      size = 20;
      text = "Done (1.0s)!";
    }
    return orig(kind, args);
  };
  assert.deepEqual(startAndWatch(w, 30), { ok: true });
});
