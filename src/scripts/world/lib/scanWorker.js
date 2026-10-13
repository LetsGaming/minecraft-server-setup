"use strict";

const { parentPort } = require("worker_threads");
const { ensureRecord } = require("./ensure");

parentPort.on("message", (job) => {
  try {
    parentPort.postMessage({ id: job.id, ...ensureRecord(job) });
  } catch (err) {
    parentPort.postMessage({ id: job.id, error: err instanceof Error ? err.message : String(err) });
  }
});
