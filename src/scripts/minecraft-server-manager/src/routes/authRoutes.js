"use strict";

const express    = require("express");
const rateLimit  = require("express-rate-limit");
const router     = express.Router();
const authController  = require("../controllers/authController");
const { isAuthenticated } = require("../middleware/authMiddleware");

// ── Login rate limiter ─────────────────────────────────────────────────────
// 10 attempts per 15 minutes per IP — prevents brute-force attacks.
const loginLimiter = rateLimit({
  windowMs:        15 * 60 * 1000,
  max:             10,
  standardHeaders: true,
  legacyHeaders:   false,
  message:         { message: "Too many login attempts. Please try again in 15 minutes." },
});

// ── Auth routes ────────────────────────────────────────────────────────────

router.get("/isAuthenticated", authController.isAuthenticated);
router.post("/login",  loginLimiter, authController.login);
router.post("/logout", authController.logout);

// ── WebSocket ticket endpoint ──────────────────────────────────────────────
// Returns a short-lived (30 s), single-use ticket that the client passes as
// the ?ticket= query param when upgrading the WebSocket. Passing the full
// session token in the URL would expose it in server access logs.
router.post("/api/ws-ticket", isAuthenticated, (req, res) => {
  const ticket = authController.generateTicket(req.user.username);
  res.json({ ticket });
});

module.exports = router;
