"use strict";

const { spawn } = require("child_process");
const config = require("../config");

/**
 * Runs a management bash script as the configured Linux user via passwordless
 * sudo (-n flag). This replaces the previous sudo -S approach that required
 * the caller to supply a plaintext password via the request body — which
 * exposed credentials in HTTP logs and server memory.
 *
 * Required sudoers entry (restrict to specific scripts):
 *   <app-user> ALL=(<linux-user>) NOPASSWD: /usr/bin/bash /path/to/scripts/*.sh
 *
 * See docs/sudoers-setup.md for the full configuration.
 */
function runScript(scriptPath, args = [], { timeoutMs = 120_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "sudo",
      ["-n", "-u", config.USER, "bash", scriptPath, ...args],
      {
        cwd:   config.SCRIPT_DIR,
        env:   { ...process.env, HOME: `/home/${config.USER}` },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );

    let stdout = "";
    let stderr = "";
    let killed = false;

    const timer = setTimeout(() => {
      killed = true;
      child.kill("SIGTERM");
      reject({
        error:  `Script timed out after ${timeoutMs / 1000}s`,
        output: stdout.trim(),
      });
    }, timeoutMs);

    child.stdout.on("data", (d) => { stdout += d.toString(); });
    child.stderr.on("data", (d) => { stderr += d.toString(); });

    child.on("close", (code) => {
      if (killed) return;
      clearTimeout(timer);

      // Filter sudo noise from stderr output
      const cleanStderr = stderr
        .split("\n")
        .filter((l) => !l.includes("[sudo]") && !l.includes("password for"))
        .join("\n")
        .trim();

      // Surface actionable sudo-misconfiguration message
      if (/sudo:.*password is required|not in the sudoers|authentication failure/i.test(cleanStderr)) {
        reject({
          error: "Passwordless sudo is not configured. See docs/sudoers-setup.md.",
          output: cleanStderr,
        });
        return;
      }

      if (code === 0) {
        resolve({ output: stdout.trim() || "Command completed successfully." });
      } else {
        reject({
          error:  `Script exited with code ${code}`,
          output: (stdout + "\n" + cleanStderr).trim(),
        });
      }
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      reject({ error: `Failed to start script: ${err.message}` });
    });
  });
}

module.exports = { runScript };
