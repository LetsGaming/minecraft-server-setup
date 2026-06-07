"use strict";

const express = require("express");
const router  = express.Router();
const { initTerminal } = require("../controllers/terminalController");
const { validateTicket } = require("../controllers/authController");

// ── WebSocket terminal ─────────────────────────────────────────────────────
// Auth uses a one-time ticket (?ticket=<hex>) obtained from POST /api/ws-ticket.
// This prevents the session token from appearing in server access logs, which
// is the risk when tokens are passed as URL query parameters.
router.ws("/ws/terminal", (ws, req) => {
  const url      = new URL(req.url, `http://${req.headers.host}`);
  const ticket   = url.searchParams.get("ticket");
  const username = validateTicket(ticket);

  if (!username) {
    ws.send("Unauthorized");
    ws.close();
    return;
  }

  req.user = { username };
  initTerminal(ws);
});

module.exports = router;
