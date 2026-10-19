// scripts/update/lib/opLock.js
//
// The instance's operation lock for the mod scripts (S-024). The shell
// scripts (restore, rollback, upgrade) take it through acquire_operation_lock
// in common/utils.sh; the mod scripts took none, so a dashboard mod change
// could land in the middle of an upgrade's apply or rollback and garble the
// manifest. Node has no flock, so a script that needs the lock re-runs
// itself under flock(1) on the same lock file and exits with its status.
// Where flock(1) is missing the shell side falls back to a mkdir lock
// (<lock>.d holding a pid file); this side does the same, so the two still
// exclude each other. If no lock can be taken the script does not run.
//
// A script started by the lock's holder (the upgrade runs update-mods and
// toggle-mod) inherits MC_OPERATION_LOCK_HELD=1 and runs straight through.

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

/** Exit status for "another operation holds the lock", as the shell scripts use. */
const EXIT_BUSY = 75;
/** How long a mod operation waits for another one to finish. */
const WAIT_SECONDS = 60;
/** A mkdir lock whose pid file is still empty is not abandoned until it is this old. */
const EMPTY_LOCK_GRACE_MS = 60_000;

function waitSeconds() {
  // Tests set a short wait; nothing else should.
  const n = Number.parseInt(process.env.MC_TEST_LOCK_WAIT ?? "", 10);
  return Number.isInteger(n) && n > 0 ? n : WAIT_SECONDS;
}

function lockDir(scriptsDir) {
  if (process.env.INSTANCE_LOCK_DIR) return process.env.INSTANCE_LOCK_DIR;
  return path.join(scriptsDir, ".locks");
}

function findFlock() {
  // Tests set this to exercise the mkdir lock on a host that has flock.
  if (process.env.MC_TEST_NO_FLOCK === "1") return null;
  const r = spawnSync("sh", ["-c", "command -v flock"], { encoding: "utf8" });
  const p = (r.stdout || "").trim();
  return r.status === 0 && p ? p : null;
}

/** Say why the script did not run, in the channel the caller reads, and exit 75. */
function exitBusy(message) {
  // The wrapper reads one JSON object from a --json run.
  if (process.argv.includes("--json")) {
    process.stdout.write(`${JSON.stringify({ ok: false, code: "busy", error: message })}\n`);
  } else {
    console.error(`${message} Exiting.`);
  }
  process.exit(EXIT_BUSY);
}

function holderOf(lock) {
  try {
    return fs.readFileSync(`${lock}.kind`, "utf8").trim() || "unknown";
  } catch {
    return "unknown";
  }
}

const busyMessage = (lock, instanceName) => `Another operation (${holderOf(lock)}) is running for ${instanceName || "this instance"}.`;

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/** True when the process that made a mkdir lock is gone (utils.sh: _lock_dir_stale). */
function mkdirLockIsStale(held) {
  let pid = "";
  try {
    pid = fs.readFileSync(path.join(held, "pid"), "utf8").trim();
  } catch {
    /* no pid yet */
  }
  if (pid) {
    try {
      process.kill(Number(pid), 0);
      return false;
    } catch (err) {
      return err.code === "ESRCH";
    }
  }
  try {
    return Date.now() - fs.statSync(held).mtimeMs > EMPTY_LOCK_GRACE_MS;
  } catch {
    return false;
  }
}

function childEnv(kind) {
  return { ...process.env, MC_OPERATION_LOCK_HELD: "1", MC_OPERATION_LOCK_KIND: kind };
}

/** Re-run this script under flock(1) on the lock file. */
function runUnderFlock(flock, lock, kind, instanceName) {
  const child = spawnSync(
    flock,
    ["-w", String(waitSeconds()), "-E", String(EXIT_BUSY), lock, process.execPath, ...process.argv.slice(1)],
    { stdio: "inherit", env: childEnv(kind) },
  );
  if (child.status === EXIT_BUSY) exitBusy(busyMessage(lock, instanceName));
  process.exit(child.status ?? 1);
}

/** Re-run this script holding the mkdir lock that utils.sh uses without flock. */
function runUnderMkdirLock(lock, kind, instanceName) {
  const held = `${lock}.d`;
  const deadline = Date.now() + waitSeconds() * 1000;
  for (;;) {
    try {
      fs.mkdirSync(held);
      break;
    } catch (err) {
      if (err.code !== "EEXIST") exitBusy(`The operation lock could not be taken (${err.message}).`);
      if (mkdirLockIsStale(held)) {
        fs.rmSync(held, { recursive: true, force: true });
        continue;
      }
      if (Date.now() >= deadline) exitBusy(busyMessage(lock, instanceName));
      sleepMs(250);
    }
  }
  let status = 1;
  try {
    fs.writeFileSync(path.join(held, "pid"), `${process.pid}\n`);
    const child = spawnSync(process.execPath, process.argv.slice(1), { stdio: "inherit", env: childEnv(kind) });
    status = child.status ?? 1;
  } finally {
    fs.rmSync(held, { recursive: true, force: true });
  }
  process.exit(status);
}

/**
 * Hold the operation lock for the rest of this process, or don't return.
 * @param {string} kind  What to record as the holder ("mods").
 * @param {{ instanceName?: string, scriptsDir: string }} where
 */
function holdOperationLock(kind, { instanceName, scriptsDir }) {
  if (process.env.MC_OPERATION_LOCK_HELD === "1") return;
  const dir = lockDir(scriptsDir);
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch (err) {
    exitBusy(`The operation lock folder could not be created (${err.message}).`);
  }
  const lock = path.join(dir, `operation_${instanceName || "default"}.lock`);
  const flock = findFlock();
  if (flock) runUnderFlock(flock, lock, kind, instanceName);
  else runUnderMkdirLock(lock, kind, instanceName);
}

/** Record what holds the lock, for the busy message others print. */
function recordLockKind({ instanceName, scriptsDir }) {
  const kind = process.env.MC_OPERATION_LOCK_KIND;
  if (!kind) return;
  try {
    fs.writeFileSync(path.join(lockDir(scriptsDir), `operation_${instanceName || "default"}.lock.kind`), `${kind}\n`);
  } catch {
    /* informational only */
  }
}

module.exports = { holdOperationLock, recordLockKind, EXIT_BUSY };

/**
 * For the scripts that change mods: take the lock (re-running under flock)
 * and record "mods" as its holder. Call before anything else happens.
 */
function guardModOperation() {
  const scriptsDir = path.resolve(__dirname, "..", "..");
  let instanceName;
  try {
    const { parseVariables } = require("./variables");
    instanceName = parseVariables(fs.readFileSync(path.join(scriptsDir, "common", "variables.txt"), "utf8")).INSTANCE_NAME;
  } catch {
    /* no variables.txt: the default lock name */
  }
  holdOperationLock("mods", { instanceName, scriptsDir });
  recordLockKind({ instanceName, scriptsDir });
}

module.exports.guardModOperation = guardModOperation;
