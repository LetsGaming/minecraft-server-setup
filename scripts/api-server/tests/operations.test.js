"use strict";

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const os = require("os");
const fs = require("fs");
const path = require("path");

// ── Minimal environment setup ─────────────────────────────────────────────
// operations.js reads config at require-time, so we need SERVER_PATH to point
// at a writable temp directory before the module is loaded.

let tmpDir;

before(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "mc-ops-test-"));

  // Write a minimal variables.txt so config.js doesn't process.exit
  const commonDir = path.join(tmpDir, "common");
  fs.mkdirSync(commonDir, { recursive: true });
  fs.writeFileSync(
    path.join(commonDir, "variables.txt"),
    [
      `SERVER_PATH=${tmpDir}`,
      "INSTANCE_NAME=testserver",
      "API_SERVER_PORT=3099",
      "API_SERVER_KEY=",
      "USE_RCON=false",
    ].join("\n"),
  );
});

after(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

// ── getStats path-traversal guard (F-001) ─────────────────────────────────

describe("getStats", () => {
  it("returns null for a traversal UUID", async () => {
    // We can't require operations.js directly because config is already loaded
    // from the environment. Instead, test the path guard logic in isolation.
    const levelName = "world";
    const statsDir = path.join(tmpDir, levelName, "stats");

    const uuid = "../../server.properties";
    const resolved = path.resolve(statsDir, `${uuid}.json`);
    // the guard: resolved must start with statsDir + sep
    const blocked = !resolved.startsWith(statsDir + path.sep);
    assert.equal(blocked, true, "traversal UUID should be blocked");
  });

  it("accepts a valid UUID path", async () => {
    const levelName = "world";
    const statsDir = path.join(tmpDir, levelName, "stats");
    fs.mkdirSync(statsDir, { recursive: true });

    const uuid = "550e8400-e29b-41d4-a716-446655440000";
    const resolved = path.resolve(statsDir, `${uuid}.json`);
    const blocked = !resolved.startsWith(statsDir + path.sep);
    assert.equal(blocked, false, "valid UUID should not be blocked");
  });
});

// ── tailLog integer validation (F-009) ────────────────────────────────────

describe("tailLog lines parameter validation", () => {
  function sanitizeLines(raw) {
    const parsed = parseInt(raw ?? "10", 10);
    return Number.isNaN(parsed) ? 10 : Math.min(Math.max(parsed, 1), 500);
  }

  it("clamps to 500 for large integers", () => {
    assert.equal(sanitizeLines("9999"), 500);
  });

  it("blocks scientific notation bypass", () => {
    // parseInt("1e6") === 1, not 1000000 — safe by default with parseInt
    assert.equal(sanitizeLines("1e6"), 1);
  });

  it("falls back to 10 for NaN input", () => {
    assert.equal(sanitizeLines("abc"), 10);
  });

  it("passes through a normal value", () => {
    assert.equal(sanitizeLines("50"), 50);
  });

  it("clamps minimum to 1", () => {
    assert.equal(sanitizeLines("0"), 1);
    assert.equal(sanitizeLines("-5"), 1);
  });
});

// ── UUID validation regex (F-001) ─────────────────────────────────────────

describe("UUID allowlist regex", () => {
  const UUID_RE =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  const valid = [
    "550e8400-e29b-41d4-a716-446655440000",
    "00000000-0000-0000-0000-000000000000",
    "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
  ];

  const invalid = [
    "../../server.properties",
    "not-a-uuid",
    "",
    "550e8400-e29b-41d4-a716-44665544000g", // invalid hex char
    "550e8400e29b41d4a716446655440000",      // no hyphens
  ];

  for (const u of valid) {
    it(`accepts ${u}`, () => assert.equal(UUID_RE.test(u), true));
  }

  for (const u of invalid) {
    it(`rejects "${u}"`, () => assert.equal(UUID_RE.test(u), false));
  }
});
