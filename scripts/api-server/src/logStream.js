"use strict";

const fs = require("fs");
const path = require("path");
const readline = require("readline");

const { SERVER_PATH, INSTANCE_NAME } = require("./config");

const LOG_FILE = path.join(SERVER_PATH, "logs", "latest.log");

const sseClients = new Set();
let logLastSize = 0;
let logReading = false;

async function processLogChanges(event) {
  if (logReading) return;
  logReading = true;
  try {
    if (event === "rename") {
      try {
        fs.accessSync(LOG_FILE);
        logLastSize = 0;
      } catch {
        return;
      }
    }

    let stat;
    try {
      stat = fs.statSync(LOG_FILE);
    } catch {
      return;
    }

    if (stat.size < logLastSize) logLastSize = 0;
    if (stat.size === logLastSize) return;

    const stream = fs.createReadStream(LOG_FILE, {
      start: logLastSize,
      end: stat.size - 1,
    });
    const rl = readline.createInterface({ input: stream });

    for await (const line of rl) {
      const payload = `data: ${JSON.stringify({ line, serverId: INSTANCE_NAME })}\n\n`;
      for (const res of [...sseClients]) {
        try {
          res.write(payload);
        } catch {
          sseClients.delete(res);
        }
      }
    }
    logLastSize = stat.size;
  } catch {
    /* swallow */
  } finally {
    logReading = false;
  }
}

function addClient(res) {
  sseClients.add(res);
}

function removeClient(res) {
  sseClients.delete(res);
}

function init() {
  // Seed offset so we don't replay the whole log on first connect
  try {
    logLastSize = fs.statSync(LOG_FILE).size;
  } catch {
    logLastSize = 0;
  }

  // fs.watch with polling fallback
  try {
    const watcher = fs.watch(path.dirname(LOG_FILE), (event, filename) => {
      if (filename === "latest.log") processLogChanges(event).catch(() => {});
    });
    watcher.on("error", () => {});
  } catch {
    /* polling only */
  }

  setInterval(() => processLogChanges("change").catch(() => {}), 1000);
}

module.exports = { init, addClient, removeClient };
