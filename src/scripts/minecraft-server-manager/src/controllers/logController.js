"use strict";

const path   = require("path");
const fs     = require("fs");
const config = require("../config");

module.exports = {
  getLogs: (req, res) => {
    // Clamp to [1, 5000] — parseInt stops at non-numeric chars so
    // scientific-notation bypasses ("1e6") resolve to 1 then clamp up.
    const raw    = parseInt(req.query.length, 10);
    const length = Number.isNaN(raw)
      ? config.LOG_LINES
      : Math.min(Math.max(raw, 1), 5000);

    const logFile = path.join(config.SERVER_PATH, "logs", "latest.log");

    if (!fs.existsSync(logFile)) {
      return res.type("text/plain").send("Log file not found. Server may not have started yet.");
    }

    fs.readFile(logFile, "utf8", (err, data) => {
      if (err) {
        return res.status(500).json({ error: "Error reading log file." });
      }
      const lines  = data.trim().split("\n");
      const output = lines.slice(-Math.min(length, lines.length)).join("\n");
      res.type("text/plain").send(output);
    });
  },
};
