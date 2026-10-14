// scripts/update/lib/opLock.js
//
// The instance's operation lock for the mod scripts (S-024). The shell
// scripts (restore, rollback, upgrade) take it through acquire_operation_lock
// in common/utils.sh; the mod scripts took none, so a dashboard mod change
// could land in the middle of an upgrade's apply or rollback and garble the
// manifest. Node has no flock, so a script that needs the lock re-runs
// itself under flock(1) on the same lock file and exits with its status.
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

function waitSeconds() {
  // Tests set a short wait; nothing else should.
  const n = Number.parseInt(process.env.MC_TEST_LOCK_WAIT ?? "", 10);
  return Number.isInteger(n) && n > 0 ? n : WAIT_SECONDS;
}

function lockDir(scriptsDir) {
  if (process.env.INSTANCE_LOCK_DIR) return process.env.INSTANCE_LOCK_DIR;
  if (process.env.XDG_RUNTIME_DIR) return path.join(process.env.XDG_RUNTIME_DIR, "minecraft");
  return path.join(scriptsDir, ".locks");
}

function findFlock() {
  const r = spawnSync("sh", ["-c", "command -v flock"], { encoding: "utf8" });
  const p = (r.stdout || "").trim();
  return r.status === 0 && p ? p : null;
}

/**
 * Hold the operation lock for the rest of this process, or don't return.
 * @param {string} kind  What to record as the holder ("mods").
 * @param {{ instanceName?: string, scriptsDir: string }} where
 */
function holdOperationLock(kind, { instanceName, scriptsDir }) {
  if (process.env.MC_OPERATION_LOCK_HELD === "1") return;
  const flock = findFlock();
  if (!flock) {
    console.warn("[WARN] flock not found; this mod operation is not serialized with other operations.");
    return;
  }
  const dir = lockDir(scriptsDir);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const lock = path.join(dir, `operation_${instanceName || "default"}.lock`);
  const child = spawnSync(
    flock,
    ["-w", String(waitSeconds()), "-E", String(EXIT_BUSY), lock, process.execPath, ...process.argv.slice(1)],
    {
      stdio: "inherit",
      env: { ...process.env, MC_OPERATION_LOCK_HELD: "1", MC_OPERATION_LOCK_KIND: kind },
    },
  );
  if (child.status === EXIT_BUSY) {
    let holder = "unknown";
    try {
      holder = fs.readFileSync(`${lock}.kind`, "utf8").trim() || holder;
    } catch {
      /* no kind recorded */
    }
    const message = `Another operation (${holder}) is running for ${instanceName || "this instance"}.`;
    // The wrapper reads one JSON object from a --json run.
    if (process.argv.includes("--json")) {
      process.stdout.write(`${JSON.stringify({ ok: false, code: "busy", error: message })}\n`);
    } else {
      console.error(`${message} Exiting.`);
    }
  }
  process.exit(child.status ?? 1);
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
