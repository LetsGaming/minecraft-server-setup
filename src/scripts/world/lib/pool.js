"use strict";

const os = require("os");
const path = require("path");
const { Worker } = require("worker_threads");
const { ensureRecord } = require("./ensure");

/** Worker count: leave a core for the rest of the host, never more than 4 by default. */
function defaultWorkers() {
  return Math.max(1, Math.min(os.cpus().length - 1, 4));
}

/**
 * Bring the cache up to date for `jobs` on a pool of worker threads, one region
 * per task. With `workers` of 0 the work runs inline. A job that fails is
 * counted and skipped (the scan that follows reads that region itself and
 * reports it), so one bad file never stops the others.
 *
 * @param {{jobs: Array<{file: string, dimId: string, rx: number, rz: number}>, cacheDir: string,
 *   workers?: number, force?: boolean, signals?: boolean, onDone?: (r: {hit: boolean, chunks: number}) => void}} args
 * @returns {Promise<{hits: number, misses: number, failed: number}>}
 */
function warmCache({ jobs, cacheDir, workers = defaultWorkers(), force = false, signals = false, onDone = () => {} }) {
  const tally = { hits: 0, misses: 0, failed: 0 };
  const note = (r) => {
    if (r.error) tally.failed++;
    else if (r.hit) tally.hits++;
    else tally.misses++;
    onDone(r);
  };

  if (workers <= 0 || jobs.length < 2) {
    for (const job of jobs) {
      try {
        note(ensureRecord({ ...job, cacheDir, force, signals }));
      } catch {
        note({ error: "failed" });
      }
    }
    return Promise.resolve(tally);
  }

  return new Promise((resolve, reject) => {
    const size = Math.min(workers, jobs.length);
    const pool = [];
    let next = 0;
    let open = 0;
    let settled = false;

    const finish = (err) => {
      if (settled) return;
      settled = true;
      for (const w of pool) void w.terminate();
      if (err) reject(err);
      else resolve(tally);
    };
    const feed = (w) => {
      if (next >= jobs.length) {
        w.finished = true;
        void w.terminate();
        if (--open === 0) finish();
        return;
      }
      const job = jobs[next];
      w.postMessage({ ...job, id: next, cacheDir, force, signals });
      next++;
    };

    for (let i = 0; i < size; i++) {
      const w = new Worker(path.join(__dirname, "scanWorker.js"));
      pool.push(w);
      open++;
      w.on("message", (r) => {
        note(r);
        feed(w);
      });
      w.on("error", finish);
      w.on("exit", (code) => {
        if (code !== 0 && !w.finished && !settled) finish(new Error(`A scan worker stopped with code ${code}.`));
      });
      feed(w);
    }
  });
}

module.exports = { warmCache, defaultWorkers };
