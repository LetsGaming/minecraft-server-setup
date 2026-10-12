"use strict";

/**
 * upgrade-server.js
 *
 * The whole server version upgrade as one supervised job, for the dashboard
 * and for SSH alike. Started through upgrade.sh, which holds the operation
 * lock for its lifetime.
 *
 *   plan check -> countdown -> stop -> archive backup -> apply (jar, mods,
 *   optional prune) -> start and watch -> success
 *                                          |
 *                    mods failed to load?  +-> disable the unavailable mods,
 *                                              start again -> success
 *                                          |
 *                    still failing?        +-> restore this job's own backup,
 *                                              start the old version
 *
 * Progress is NDJSON on stdout (and the same lines in the status file), one
 * object per line: {seq, ts, phase, status, msg} and a final {type:"result"}.
 *
 * Usage: node upgrade-server.js <version> [--expect-unavailable=a,b]
 *          [--countdown=<seconds>] [--start-timeout=<seconds>]
 *          [--prune-plan=<file>]
 */

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { parseArgs } = require("./lib/args");
const { loadVariables } = require("./lib/variables");

const DEFAULT_COUNTDOWN_SECONDS = 30;
const DEFAULT_START_TIMEOUT_SECONDS = 300;
const POLL_SECONDS = 2;

const READY_PATTERN = /Done \(\d+(?:\.\d+)?s\)/;

/**
 * @typedef {object} Deps
 * @property {(kind: "ops"|"backup"|"restore"|"toggle"|"update", args: string[]) => {code: number, stdout: string, stderr: string}} run
 * @property {(seconds: number) => void} sleep
 * @property {() => number} now  epoch milliseconds
 * @property {(obj: object) => void} emit
 * @property {{ size(): number, since(offset: number): string }} log   latest.log
 * @property {{ size(): number, since(offset: number): string }} events lifecycle.ndjson
 * @property {() => string[]} listArchives   names in archives/update
 * @property {(name: string) => string} archivePath absolute path of an archive name
 * @property {() => string|null} readVersionsFile
 * @property {(text: string|null) => void} writeVersionsFile
 */

/** Text written to a file since `offset`; a file shorter than that was rotated and is read whole. */
function tail(handle, offset) {
  return handle.since(handle.size() < offset ? 0 : offset);
}

/**
 * Starts the server and waits for it to be playable or visibly broken.
 * Returns {ok:true} or {ok:false, reason:"crash_loop"|"timeout"}.
 */
function startAndWatch(deps, timeoutSeconds) {
  const logOffset = deps.log.size();
  const eventsOffset = deps.events.size();
  const started = deps.run("ops", ["start"]);
  if (started.code !== 0) return { ok: false, reason: "start_failed" };

  const deadline = deps.now() + timeoutSeconds * 1000;
  for (;;) {
    const events = tail(deps.events, eventsOffset);
    if (events.includes('"type":"crash_loop_gave_up"')) {
      return { ok: false, reason: "crash_loop" };
    }
    if (READY_PATTERN.test(tail(deps.log, logOffset))) return { ok: true };
    if (deps.now() >= deadline) return { ok: false, reason: "timeout" };
    deps.sleep(POLL_SECONDS);
  }
}

function parseLines(text) {
  const out = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      /* not one of ours */
    }
  }
  return out;
}

/**
 * Runs the upgrade. Never throws for an expected failure: the outcome is the
 * returned result (also emitted as the last NDJSON line).
 *
 * @param {Deps} deps
 * @param {{version: string, expectUnavailable: string[]|null, countdown: number,
 *          startTimeout: number, prune: boolean}} opts
 */
function runUpgrade(deps, opts) {
  let seq = 0;
  const say = (phase, status, msg, extra = {}) =>
    deps.emit({ seq: ++seq, ts: Math.floor(deps.now() / 1000), phase, status, msg, ...extra });
  const finish = (result) => {
    deps.emit({ seq: ++seq, ts: Math.floor(deps.now() / 1000), type: "result", ...result });
    return result;
  };

  let serverStopped = false;
  let archive = null;
  const versionsBefore = deps.readVersionsFile();

  const restartAfterAbort = (why) => {
    if (!serverStopped) return;
    say("abort", "info", `Starting the server again (${why})`);
    deps.run("ops", ["start"]);
    serverStopped = false;
  };

  const rollback = (reason) => {
    say("rollback", "running", "Restoring the backup taken for this upgrade");
    deps.run("ops", ["halt"]);
    const restored = deps.run("restore", ["--y", "--archive", "--file", deps.archivePath(archive)]);
    if (restored.code !== 0) {
      say("rollback", "error", "The restore failed. The server is stopped; restore the backup by hand.", {
        archive,
      });
      return finish({ ok: false, rolledBack: false, reason: "rollback_failed", cause: reason, archive });
    }
    deps.writeVersionsFile(versionsBefore);
    const back = startAndWatch(deps, opts.startTimeout);
    say("rollback", back.ok ? "done" : "error", back.ok ? "The previous version is running again" : "Restored, but the server did not report ready");
    return finish({
      ok: false,
      rolledBack: true,
      reason,
      archive,
      previousVersionRunning: back.ok,
    });
  };

  // ── plan check ──
  say("plan", "running", `Checking ${opts.version}`);
  const planRun = deps.run("update", [opts.version, "--plan", "--json"]);
  const plan = parseLines(planRun.stdout).find((l) => "ok" in l);
  if (planRun.code !== 0 || !plan || !plan.ok) {
    say("plan", "error", plan?.error ?? "The plan check failed");
    return finish({ ok: false, rolledBack: false, reason: "plan_failed", detail: plan?.error ?? planRun.stderr });
  }
  const unavailable = [...plan.unavailable].sort();
  if (opts.expectUnavailable) {
    const expected = [...opts.expectUnavailable].sort();
    if (JSON.stringify(expected) !== JSON.stringify(unavailable)) {
      say("plan", "error", "The installed mods changed since the compatibility check. Run the check again.");
      return finish({
        ok: false,
        rolledBack: false,
        reason: "mods_changed",
        expected,
        found: unavailable,
      });
    }
  }
  say("plan", "done", `${plan.current ?? "?"} to ${plan.target}`, { unavailable, java: plan.java });

  deps.run("ops", ["notify", "update_start", `Upgrading to ${plan.target}`]);

  // ── countdown ──
  if (opts.countdown > 0) {
    say("countdown", "running", `Players are warned, ${opts.countdown}s`);
    deps.run("ops", ["announce", `The server restarts in ${opts.countdown} seconds for an upgrade to ${plan.target}.`]);
    deps.sleep(opts.countdown);
  }

  // ── stop ──
  say("stop", "running", "Saving and stopping the server");
  const stopped = deps.run("ops", ["stop"]);
  if (stopped.code !== 0) {
    say("stop", "error", "The server did not stop. Nothing was changed.");
    return finish({ ok: false, rolledBack: false, reason: "stop_failed" });
  }
  serverStopped = true;

  // ── backup ──
  say("backup", "running", "Archive backup of the server");
  const before = new Set(deps.listArchives());
  const backedUp = deps.run("backup", ["--archive", "update"]);
  archive = deps.listArchives().find((name) => !before.has(name)) ?? null;
  if (backedUp.code !== 0 || !archive) {
    say("backup", "error", "The backup failed. Nothing was changed.");
    restartAfterAbort("backup failed");
    return finish({ ok: false, rolledBack: false, reason: "backup_failed" });
  }
  say("backup", "done", archive, { archive });

  // ── apply ──
  say("apply", "running", "Installing the new version");
  const applied = deps.run("update", [opts.version, "--apply", "--json"]);
  const applyLines = parseLines(applied.stdout);
  for (const line of applyLines) {
    if (line.phase) say(`apply.${line.phase}`, "running", line.msg ?? "");
  }
  const applyEnd = applyLines.find((l) => "ok" in l);
  if (applied.code !== 0 || !applyEnd || !applyEnd.ok) {
    say("apply", "error", applyEnd?.error ?? "The install failed");
    return rollback("apply_failed");
  }
  say("apply", "done", `Installed ${plan.target}`);

  if (opts.prune) {
    say("prune", "running", "Pruning unused chunks");
    const pruned = deps.run("prune", ["--apply"]);
    if (pruned.code !== 0) {
      say("prune", "error", "The prune failed. The whole upgrade is rolled back.");
      return rollback("prune_failed");
    }
    say("prune", "done", "Chunks pruned");
  }

  // ── start, first try: every mod as it is ──
  say("start", "running", "Starting the new version");
  let outcome = startAndWatch(deps, opts.startTimeout);
  if (outcome.ok) {
    say("start", "done", "The server is up");
    deps.run("ops", ["notify", "update_complete", `Server upgraded to ${plan.target}`]);
    return finish({
      ok: true,
      branch: "clean",
      target: plan.target,
      archive,
      disabled: [],
      keptOnOldBuild: unavailable,
    });
  }
  say("start", "error", `The server did not come up (${outcome.reason})`);
  deps.run("ops", ["halt"]);

  // ── second try: the mods with no build for this version are disabled ──
  const disabled = [];
  if (unavailable.length > 0) {
    say("mods", "running", `Disabling ${unavailable.length} mod(s) with no build for ${plan.target}`);
    for (const slug of unavailable) {
      const r = deps.run("toggle", [slug, "--disable", "--json"]);
      if (r.code === 0) disabled.push(slug);
    }
    say("mods", "done", `Disabled: ${disabled.join(", ") || "none"}`, { disabled });
    say("start", "running", "Starting again without them");
    outcome = startAndWatch(deps, opts.startTimeout);
    if (outcome.ok) {
      say("start", "done", "The server is up");
      deps.run("ops", ["notify", "update_complete", `Server upgraded to ${plan.target}; disabled: ${disabled.join(", ")}`]);
      return finish({
        ok: true,
        branch: "mods_disabled",
        target: plan.target,
        archive,
        disabled,
        keptOnOldBuild: unavailable.filter((s) => !disabled.includes(s)),
      });
    }
    say("start", "error", `Still not up (${outcome.reason})`);
    deps.run("ops", ["halt"]);
  }

  // ── last resort: the old version, from this job's own backup ──
  deps.run("ops", ["notify", "update_failed", `Upgrade to ${plan.target} failed; rolling back`]);
  return rollback(outcome.reason);
}

// ── Real dependencies ─────────────────────────────────────────────────────

function realDeps({ scriptsDir, serverPath, backupsPath, statusFile }) {
  const scripts = {
    ops: ["bash", path.join(scriptsDir, "common", "instance_ops.sh")],
    backup: ["bash", path.join(scriptsDir, "backup", "backup.sh")],
    restore: ["bash", path.join(scriptsDir, "backup", "restore.sh")],
    toggle: ["node", path.join(scriptsDir, "update", "toggle-mod.js")],
    update: ["node", path.join(scriptsDir, "update", "update-server.js")],
    prune: ["node", path.join(scriptsDir, "update", "prune-chunks.js")],
  };
  const archivesDir = path.join(backupsPath, "archives", "update");
  const versionsFile = path.join(scriptsDir, "common", "downloaded_versions.json");
  const fileHandle = (file) => ({
    size: () => {
      try {
        return fs.statSync(file).size;
      } catch {
        return 0;
      }
    },
    since: (offset) => {
      try {
        const buf = fs.readFileSync(file);
        return buf.subarray(offset).toString("utf8");
      } catch {
        return "";
      }
    },
  });
  const sleeper = new Int32Array(new SharedArrayBuffer(4));

  fs.writeFileSync(statusFile, "");

  return {
    run(kind, args) {
      const [cmd, script] = scripts[kind];
      const r = spawnSync(cmd, [script, ...args], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
      return { code: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    },
    sleep: (seconds) => Atomics.wait(sleeper, 0, 0, seconds * 1000),
    now: () => Date.now(),
    emit(obj) {
      const line = JSON.stringify(obj) + "\n";
      process.stdout.write(line);
      try {
        fs.appendFileSync(statusFile, line);
      } catch {
        /* the stream above is the primary channel */
      }
    },
    log: fileHandle(path.join(serverPath, "logs", "latest.log")),
    events: fileHandle(path.join(serverPath, "logs", "lifecycle.ndjson")),
    listArchives: () => {
      try {
        return fs.readdirSync(archivesDir).filter((n) => /\.tar\.(zst|gz)$/.test(n));
      } catch {
        return [];
      }
    },
    archivePath: (name) => path.join(archivesDir, name),
    readVersionsFile: () => {
      try {
        return fs.readFileSync(versionsFile, "utf8");
      } catch {
        return null;
      }
    },
    writeVersionsFile: (text) => {
      if (text !== null) fs.writeFileSync(versionsFile, text, "utf8");
    },
  };
}

function main() {
  const args = parseArgs({
    flags: { version: null, "expect-unavailable": null, countdown: null, "start-timeout": null, "prune-plan": null },
    positional: ["version"],
  });
  const version = args.get("version");
  if (!version) {
    console.error("Usage: node upgrade-server.js <version> [--expect-unavailable=a,b] [--countdown=s] [--start-timeout=s]");
    process.exit(64);
  }
  const scriptsDir = path.resolve(__dirname, "..");
  const vars = loadVariables(path.join(scriptsDir, "common", "variables.txt"));
  const num = (v, d) => (v === null || Number.isNaN(Number(v)) ? d : Number(v));
  const expect = args.get("expect-unavailable");

  const deps = realDeps({
    scriptsDir,
    serverPath: vars.SERVER_PATH,
    backupsPath: vars.BACKUPS_PATH,
    statusFile: path.join(scriptsDir, "common", "upgrade-status.ndjson"),
  });
  const result = runUpgrade(deps, {
    version,
    expectUnavailable: expect === null ? null : expect.split(",").filter(Boolean),
    countdown: num(args.get("countdown"), DEFAULT_COUNTDOWN_SECONDS),
    startTimeout: num(args.get("start-timeout"), DEFAULT_START_TIMEOUT_SECONDS),
    prune: args.get("prune-plan") !== null,
  });
  process.exit(result.ok ? 0 : 1);
}

if (require.main === module) {
  main();
}

module.exports = { runUpgrade, startAndWatch, READY_PATTERN };
