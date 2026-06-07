"use strict";

const bcrypt  = require("bcrypt");
const fs      = require("fs");
const path    = require("path");
const crypto  = require("crypto");
const config  = require("../config");

const usersFile = path.join(__dirname, "..", "config", "users.json");

// ── Shared TTL constant ────────────────────────────────────────────────────
// Exported so authMiddleware.js uses the same value — single source of truth.
const TTL_MS = (config.SESSION_TTL_HOURS || 24) * 3600 * 1000;
exports.TTL_MS = TTL_MS;

// ── Session token store ────────────────────────────────────────────────────
// token (64-hex) → { username, created }
const tokenStore = new Map();
exports.tokenStore = tokenStore;

// ── One-time WebSocket ticket store ───────────────────────────────────────
// Short-lived (30 s), single-use tickets avoid exposing session tokens in
// the WebSocket URL query string, where they appear in server access logs.
const TICKET_TTL_MS = 30_000;
const ticketStore   = new Map(); // ticket (32-hex) → { username, expiresAt }

// ── Helpers ────────────────────────────────────────────────────────────────

function loadUsers() {
  if (!fs.existsSync(usersFile)) return [];
  try {
    return JSON.parse(fs.readFileSync(usersFile, "utf-8"));
  } catch {
    return [];
  }
}

function pruneExpiredTokens() {
  const now = Date.now();
  for (const [token, data] of tokenStore) {
    if (now - data.created > TTL_MS) tokenStore.delete(token);
  }
}

function validateToken(token) {
  if (!token) return null;
  pruneExpiredTokens();
  const data = tokenStore.get(token);
  if (!data) return null;
  // Verify the user still exists (handles account deletion)
  const users = loadUsers();
  if (!users.find((u) => u.username === data.username)) {
    tokenStore.delete(token);
    return null;
  }
  return data.username;
}

// ── Ticket helpers (exported for terminalRoutes) ───────────────────────────

/** Issue a single-use 30-second WebSocket ticket for an authenticated user. */
exports.generateTicket = (username) => {
  const ticket = crypto.randomBytes(16).toString("hex");
  ticketStore.set(ticket, { username, expiresAt: Date.now() + TICKET_TTL_MS });
  return ticket;
};

/**
 * Validate and consume a WebSocket ticket.
 * Returns the username on success, null on any failure.
 * Single-use: the ticket is deleted on first call regardless of expiry.
 */
exports.validateTicket = (ticket) => {
  if (!ticket) return null;
  const data = ticketStore.get(ticket);
  ticketStore.delete(ticket); // always consume — single-use
  if (!data) return null;
  if (Date.now() > data.expiresAt) return null;
  return data.username;
};

// ── Auth endpoints ─────────────────────────────────────────────────────────

exports.isAuthed = (token) => !!validateToken(token);

exports.isAuthenticated = (req, res) => {
  const token    = req.headers.authorization?.split(" ")[1];
  const username = validateToken(token);
  if (!username) return res.status(401).json({ message: "Unauthorized" });
  res.json({ message: "Authenticated", username });
};

exports.login = async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ message: "Username and password required." });
  }

  const users = loadUsers();
  const user  = users.find((u) => u.username === username);
  // Always run bcrypt.compare even when user is not found to prevent
  // user-enumeration via timing differences.
  const hash  = user?.passwordHash ?? "$2b$10$invalidhashpadding000000000000000000000000000000000000";
  const valid = await bcrypt.compare(password, hash);
  if (!user || !valid) {
    return res.status(401).json({ message: "Invalid credentials" });
  }

  const token = crypto.randomBytes(32).toString("hex");
  tokenStore.set(token, { username, created: Date.now() });
  res.json({ token });
};

exports.logout = (req, res) => {
  const token = req.headers.authorization?.split(" ")[1];
  if (token) tokenStore.delete(token);
  res.status(200).json({ message: "Logged out." });
};
