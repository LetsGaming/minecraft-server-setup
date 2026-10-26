#!/usr/bin/env node
"use strict";

// Writes the creative mirror target settings given as command line flags
// (--mirror-target, --mirror-remote, --mirror-seed) into variables.json, so the
// Default route can set up a target without editing the file by hand.
//
// Usage: node apply_mirror_flags.js <variables.json> [--remote HOST] [--seed SEED]
// Exit: 0 written, 1 invalid input or unreadable file.

const fs = require("fs");

const HOST_RE = /^[A-Za-z0-9._:-]+$/;
const SEED_RE = /^-?[A-Za-z0-9_.-]{1,64}$/;

function normaliseRemote(remote) {
  const host = String(remote).replace(/^mcsync@/, "");
  if (!HOST_RE.test(host)) throw new Error("the mirror remote must be a host name or address, optionally written mcsync@host");
  return `mcsync@${host}`;
}

function applyMirrorFlags(file, { remote, seed }) {
  const data = JSON.parse(fs.readFileSync(file, "utf8"));
  const mirror = data.MIRROR && typeof data.MIRROR === "object" ? data.MIRROR : {};
  mirror.ENABLED = true;
  mirror.ROLE = "target";
  if (remote) mirror.REMOTE = normaliseRemote(remote);
  data.MIRROR = mirror;
  if (seed !== undefined && seed !== "") {
    if (!SEED_RE.test(String(seed))) throw new Error("the mirror seed may only contain letters, digits, - _ . (the survival world's level-seed)");
    data.JAVA = data.JAVA || {};
    data.JAVA.SERVER = data.JAVA.SERVER || {};
    data.JAVA.SERVER.SEED = String(seed);
  }
  const mode = fs.statSync(file).mode & 0o777;
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", { mode });
  fs.renameSync(tmp, file);
}

module.exports = { applyMirrorFlags, normaliseRemote, HOST_RE, SEED_RE };

if (require.main === module) {
  const [file, ...rest] = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    if (rest[i] === "--remote") opts.remote = rest[i + 1];
    else if (rest[i] === "--seed") opts.seed = rest[i + 1];
    else {
      console.error(`unknown argument: ${rest[i]}`);
      process.exit(1);
    }
  }
  if (!file) {
    console.error("Usage: node apply_mirror_flags.js <variables.json> [--remote HOST] [--seed SEED]");
    process.exit(1);
  }
  try {
    applyMirrorFlags(file, opts);
  } catch (err) {
    console.error(`Could not apply the mirror options: ${err.message}`);
    process.exit(1);
  }
}
