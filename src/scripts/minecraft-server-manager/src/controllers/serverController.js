"use strict";

const { runScript } = require("../utils/runScript");
const { sendRconCommand, isRconAvailable } = require("../utils/rcon");
const config = require("../config");

/**
 * Creates a handler that runs a named management script.
 * Scripts run via passwordless sudo — no password is accepted from the caller.
 */
const handleScript = (scriptKey, successMsg, opts = {}) => async (req, res) => {
  const script = config.SCRIPTS[scriptKey];
  if (!script) {
    return res.status(400).json({ error: `Unknown script: ${scriptKey}` });
  }
  try {
    const result = await runScript(script, opts.args || [], {
      timeoutMs: opts.timeoutMs || 120_000,
    });
    res.json(result || { message: successMsg });
  } catch (err) {
    res.status(500).json(err);
  }
};

module.exports = {
  status: async (req, res) => {
    if (isRconAvailable()) {
      try {
        const response = await sendRconCommand("list");
        return res.json({ output: `Server Status: Running\n| ${response}` });
      } catch { /* fall through */ }
    }
    try {
      const result = await runScript(config.SCRIPTS.status);
      res.json(result);
    } catch {
      res.json({ output: "Server Status: Not Running" });
    }
  },

  start:        handleScript("start",        "Server started."),
  shutdown:     handleScript("shutdown",      "Server shut down."),
  restart:      handleScript("restart",       "Server restarted."),
  smartRestart: handleScript("smartRestart",  "Server restarted (smart)."),

  rollback: async (req, res) => {
    try {
      const result = await runScript(config.SCRIPTS.rollback, ["--y"], {
        timeoutMs: 300_000,
      });
      res.json(result || { message: "Rollback complete." });
    } catch (err) {
      res.status(500).json(err);
    }
  },

  sendCommand: async (req, res) => {
    const { command } = req.body;
    if (!command) return res.status(400).json({ error: "No command provided." });

    const normalized = command.trim().toLowerCase();
    if (config.BLOCKED_COMMANDS.some((b) => normalized.startsWith(b))) {
      return res.status(403).json({ error: `Command blocked: ${command}` });
    }

    if (isRconAvailable()) {
      try {
        const response = await sendRconCommand(command.replace(/^\//, ""));
        return res.json({ output: response || "Command sent." });
      } catch (err) {
        return res.status(500).json({ error: `RCON error: ${err.message}` });
      }
    }

    res.status(400).json({ error: "RCON not configured. Use the terminal for commands." });
  },
};
