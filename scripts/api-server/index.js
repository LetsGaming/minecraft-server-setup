"use strict";

const fs = require("fs");
const path = require("path");
const express = require("express");

const { PORT, API_KEY, INSTANCE_NAME } = require("./src/config");
const logStream = require("./src/logStream");
const instancesRouter = require("./src/routes/instances");

// ── Express app ───────────────────────────────────────────────────────────

const app = express();
app.use(express.json());

// Ensure log directory exists (used by PM2 / ecosystem.config.cjs)
const LOG_DIR = path.join(__dirname, "logs");
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

// NOTE: /health is intentionally registered BEFORE the auth middleware.
// It must stay above app.use(authMiddleware) to remain publicly accessible
// for uptime monitors. The instance name is NOT exposed here to avoid
// leaking internal config to unauthenticated callers.
app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

// Auth middleware — all routes below this point require a valid API key
app.use((req, res, next) => {
  if (!API_KEY) return next();
  const key = req.headers["x-api-key"] || "";
  if (key !== API_KEY) {
    res.status(401).json({ error: "Unauthorized" });
    return;
  }
  next();
});

// Instance routes
app.use("/instances", instancesRouter);

// ── Start ─────────────────────────────────────────────────────────────────

logStream.init();

app.listen(PORT, () => {
  console.log(`[api-server] ${INSTANCE_NAME} — listening on :${PORT}`);
});
