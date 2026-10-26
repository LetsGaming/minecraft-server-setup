#!/usr/bin/env node
"use strict";

// Makes sure variables.json has a usable API key before the wrapper is
// deployed. A wrapper started without one exits at once and systemd restarts it
// forever (`--default --api-server` used to write an empty key). A key that
// is already long enough is kept. The key is never printed.
//
// Usage: node ensure_api_key.js <path-to-variables.json>
// Exit: 0 key present or generated, 1 variables.json unreadable.

const fs = require("fs");
const crypto = require("crypto");

const MIN_KEY_LENGTH = 32;
// Long enough to pass the length check, but loadVariables rejects it.
const EXAMPLE_API_KEYS = ["replace-with-a-long-random-secret"];

function ensureApiKey(file) {
  const raw = fs.readFileSync(file, "utf8");
  const data = JSON.parse(raw);
  const api = data.API_SERVER && typeof data.API_SERVER === "object" ? data.API_SERVER : {};
  const rawKey = typeof api.API_KEY === "string" ? api.API_KEY : "";
  const key = EXAMPLE_API_KEYS.includes(rawKey) ? "" : rawKey;
  if (key.length >= MIN_KEY_LENGTH && api.ENABLED === true) return false;

  data.API_SERVER = { ...api, ENABLED: true };
  if (key.length < MIN_KEY_LENGTH) data.API_SERVER.API_KEY = crypto.randomBytes(32).toString("hex");

  const mode = fs.statSync(file).mode & 0o777;
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", { mode });
  fs.renameSync(tmp, file);
  return true;
}

module.exports = { ensureApiKey, MIN_KEY_LENGTH };

if (require.main === module) {
  const file = process.argv[2];
  if (!file) {
    console.error("Usage: node ensure_api_key.js <path-to-variables.json>");
    process.exit(1);
  }
  try {
    if (ensureApiKey(file)) {
      console.log(`API wrapper requested: ${file} now has API_SERVER.ENABLED=true and a generated API key (not shown).`);
    }
  } catch (err) {
    console.error(`Could not prepare the API key in ${file}: ${err.message}`);
    process.exit(1);
  }
}
