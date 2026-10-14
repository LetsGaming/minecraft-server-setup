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
 * --expect-unavailable is the list of mods a person was shown as unavailable
 * or unchecked. The job refuses to start only if its own check finds a mod
 * with no build that is not on that list.
 *
 * Usage: node upgrade-server.js <version> [--expect-unavailable=a,b]
 *          [--countdown=<seconds>] [--start-timeout=<seconds>]
 *          [--prune-plan=<id>]
 *        node upgrade-server.js --prune-only --prune-plan=<id>
 *          [--countdown=<seconds>] [--start-timeout=<seconds>]
 *
 * With --prune-plan the chunk prune runs after the install and before the
 * first start of the new version, under the same backup, so a failed prune
 * rolls the whole job back. --prune-only is the same job without the version
 * change: stop, back up, prune, start.
 */

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { parseArgs } = require("./lib/args");

/** Ceilings for each step of the job (S-015). Generous: a timeout here means wedged. */
const STEP_TIMEOUT_MS = {
  ops: 15 * 60_000,
  backup: 3 * 60 * 60_000,
  restore: 2 * 60 * 60_000,
  update: 45 * 60_000,
  toggle: 5 * 60_000,
  prune: 3 * 60 * 60_000,
};

/** A Minecraft version id: 1.21.4, 24w14a, 1.21-pre1. Never something that starts like a flag. */
const VERSION_RE = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,39}$/;
const { loadVariables } = require("./lib/variables");

/** The prune stops itself after this long and the job rolls back, rather than being killed mid-delete. */
const PRUNE_TIME_BUDGET_SECONDS = 45 * 60;
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
 * @param {{version: string|null, expectUnavailable: string[]|null, countdown: number,
 *          startTimeout: number, prunePlan: string|null}} opts  `version` null
 *   means a prune-only job: no install, no mod handling.
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
  let plan;
  let unavailable = [];
  if (opts.version) {
    say("plan", "running", `Checking ${opts.version}`);
    // After "--" (S-022): a version can never be read as a flag of update-server.
    const planRun = deps.run("update", ["--plan", "--json", "--", opts.version]);
    plan = parseLines(planRun.stdout).find((l) => "ok" in l);
    if (planRun.code !== 0 || !plan || !plan.ok) {
      say("plan", "error", plan?.error ?? "The plan check failed");
      return finish({ ok: false, rolledBack: false, reason: "plan_failed", detail: plan?.error ?? planRun.stderr });
    }
    unavailable = [...plan.unavailable].sort();
    // The person confirmed a list of mods that may be disabled if the new
    // version does not start. Refuse only when this check finds one with no
    // build that was not on it. A listed mod that turns out fine is no reason
    // to stop: the dashboard also lists mods whose check failed (a timeout, a
    // rate limit), and those usually resolve here.
    if (opts.expectUnavailable) {
      const expected = [...opts.expectUnavailable].sort();
      const unexpected = unavailable.filter((slug) => !expected.includes(slug));
      if (unexpected.length > 0) {
        say(
          "plan",
          "error",
          `No build for ${plan.target}, and not in the list you confirmed: ${unexpected.join(", ")}. Run the check again.`,
        );
        return finish({
          ok: false,
          rolledBack: false,
          reason: "mods_changed",
          expected,
          found: unavailable,
          unexpected,
        });
      }
    }
    say("plan", "done", `${plan.current ?? "?"} to ${plan.target}`, { unavailable, java: plan.java });
  } else {
    plan = { ok: true, current: null, target: null, unavailable: [], java: null };
    say("plan", "done", "Chunk prune only");
  }
  const what = plan.target ? `Upgrading to ${plan.target}` : "Pruning unused chunks";

  deps.run("ops", ["notify", "update_start", what]);

  // ── countdown ──
  if (opts.countdown > 0) {
    say("countdown", "running", `Players are warned, ${opts.countdown}s`);
    deps.run("ops", [
      "announce",
      plan.target
        ? `The server restarts in ${opts.countdown} seconds for an upgrade to ${plan.target}.`
        : `The server restarts in ${opts.countdown} seconds to clean up unused chunks.`,
    ]);
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
  if (opts.version) {
    say("apply", "running", "Installing the new version");
    const applied = deps.run("update", ["--apply", "--json", "--", opts.version]);
    const applyLines = parseLines(applied.stdout);
    for (const line of applyLines) {
      if (line.phase) say(`apply.${line.phase}`, "running", line.msg ?? "");
    }
    const applyEnd = applyLines.find((l) => "ok" in l);
    if (applied.code !== 0 || !applyEnd || !applyEnd.ok) {
      say("apply", "error", applyEnd?.error ?? "The install failed");
      return rollback("apply_failed");
    }
    // Mods whose update failed are still on their old build (S-014); say so
    // and report them with the ones that had no build at all.
    for (const slug of applyEnd.modUpdateFailed ?? []) {
      if (!unavailable.includes(slug)) unavailable.push(slug);
    }
    if ((applyEnd.modUpdateFailed ?? []).length > 0) {
      say("apply.mods", "error", `Not updated, still on the old build: ${applyEnd.modUpdateFailed.join(", ")}`);
    }
    say("apply", "done", `Installed ${plan.target}`);
  }

  // Pruning sits after the install and before the first start: the new version
  // never spends time upgrading chunks that are about to go, and one backup
  // covers the jar, the mods and the prune.
  let pruneResult = null;
  if (opts.prunePlan) {
    say("prune", "running", "Deleting unused chunks");
    const pruned = deps.run("prune", ["--apply", `--plan=${opts.prunePlan}`, `--time-budget=${PRUNE_TIME_BUDGET_SECONDS}`, "--json"]);
    pruneResult = parseLines(pruned.stdout).find((l) => "ok" in l) ?? null;
    if (pruned.code !== 0 || !pruneResult || !pruneResult.ok) {
      say("prune", "error", pruneResult?.error ?? "The prune failed. The whole job is rolled back.");
      return rollback(pruneResult?.code === "plan_stale" ? "prune_stale" : pruneResult?.code === "time_budget" ? "prune_timeout" : "prune_failed");
    }
    say("prune", "done", `${pruneResult.deletedChunks} chunks deleted`, {
      deletedChunks: pruneResult.deletedChunks,
      bytesFreed: pruneResult.bytesFreed,
    });
  }
  const pruned = pruneResult
    ? { prunedChunks: pruneResult.deletedChunks, bytesFreed: pruneResult.bytesFreed }
    : {};

  // ── start, first try: every mod as it is ──
  say("start", "running", "Starting the new version");
  let outcome = startAndWatch(deps, opts.startTimeout);
  if (outcome.ok) {
    say("start", "done", "The server is up");
    deps.run("ops", ["notify", "update_complete", plan.target ? `Server upgraded to ${plan.target}` : "Unused chunks pruned"]);
    return finish({
      ok: true,
      branch: "clean",
      target: plan.target,
      archive,
      disabled: [],
      keptOnOldBuild: unavailable,
      ...pruned,
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
        ...pruned,
      });
    }
    say("start", "error", `Still not up (${outcome.reason})`);
    deps.run("ops", ["halt"]);
  }

  // ── last resort: the old version, from this job's own backup ──
  deps.run("ops", ["notify", "update_failed", `${what} failed; rolling back`]);
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
    prune: ["node", path.join(scriptsDir, "world", "prune-chunks.js")],
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
      // S-015: every step has a ceiling, so one that hangs (a stalled download,
      // a wedged JVM) cannot keep the server down and the lock held forever.
      const r = spawnSync(cmd, [script, ...args], {
        // The prune runs only after this job's backup (S-025); this is how
        // prune-chunks.js knows there is one.
        ...(kind === "prune" ? { env: { ...process.env, MC_PRUNE_BACKED_UP: "1" } } : {}),
        encoding: "utf8",
        maxBuffer: 16 * 1024 * 1024,
        timeout: STEP_TIMEOUT_MS[kind] ?? 30 * 60_000,
        killSignal: "SIGTERM",
      });
      const timedOut = r.error && r.error.code === "ETIMEDOUT";
      return {
        code: r.status ?? 1,
        stdout: r.stdout ?? "",
        stderr: (r.stderr ?? "") + (timedOut ? `\n${kind} timed out` : ""),
      };
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
    boolFlags: ["prune-only"],
    positional: ["version"],
  });
  const pruneOnly = args.bool("prune-only");
  const prunePlan = args.get("prune-plan");
  const version = pruneOnly ? null : args.get("version");
  // S-022: a version like "--version=--yes" was read as a flag downstream and
  // upgraded to the latest release instead of the one asked for.
  if (version !== null && !VERSION_RE.test(version)) {
    console.error(`Not a Minecraft version: ${JSON.stringify(version)}`);
    process.exit(2);
  }
  if (!version && !(pruneOnly && prunePlan)) {
    console.error("Usage: node upgrade-server.js <version> [--prune-plan=id] | --prune-only --prune-plan=id");
    process.exit(64);
  }
  if (prunePlan && !/^[a-f0-9]{16}$/.test(prunePlan)) {
    console.error("--prune-plan must be a plan id.");
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
    prunePlan: prunePlan ?? null,
  });
  process.exit(result.ok ? 0 : 1);
}

if (require.main === module) {
  main();
}

module.exports = { runUpgrade, startAndWatch, READY_PATTERN };
