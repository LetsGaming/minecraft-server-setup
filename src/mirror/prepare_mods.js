#!/usr/bin/env node
"use strict";

// Installs the mods a creative mirror target needs into a server's mods folder,
// by exact version where one is pinned (pins.json), with the SHA-512 Modrinth
// publishes checked before a jar is kept. Needs Node 18 or newer (fetch).
//
// Usage: node prepare_mods.js --mods-dir DIR --mc-version V [--pins FILE] [--dry-run]
// Env:   MODRINTH_API  base URL of the API (tests point it at a local server)
// Exit:  0 done, 1 a mod could not be installed.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const API = (process.env.MODRINTH_API || "https://api.modrinth.com/v2").replace(/\/$/, "");
const UA = "minecraft-server-setup mirror prepare";

function parseArgs(argv) {
  const out = { dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mods-dir") out.modsDir = argv[++i];
    else if (a === "--mc-version") out.mcVersion = argv[++i];
    else if (a === "--pins") out.pins = argv[++i];
    else if (a === "--dry-run") out.dryRun = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!out.modsDir || !out.mcVersion) throw new Error("--mods-dir and --mc-version are required");
  if (!/^[0-9A-Za-z._-]+$/.test(out.mcVersion)) throw new Error("--mc-version has unexpected characters");
  return out;
}

async function getJson(url) {
  const res = await fetch(url, { headers: { "User-Agent": UA } });
  if (!res.ok) throw new Error(`${url} answered ${res.status}`);
  return res.json();
}

function jarsFor(modsDir, slug) {
  const key = slug.replace(/-/g, "").toLowerCase();
  let names = [];
  for (const dir of [modsDir, path.join(modsDir, "disabled")]) {
    try {
      names = names.concat(fs.readdirSync(dir).map((n) => ({ dir, n })));
    } catch {
      /* no such folder */
    }
  }
  return names.filter(({ n }) => n.endsWith(".jar") && n.replace(/[-_]/g, "").toLowerCase().includes(key));
}

// The version to install: the pinned one for this Minecraft version, else the
// newest release. Returns { version, pinned }.
function chooseVersion(versions, slug, mcVersion, pins) {
  const pinned = pins?.[slug]?.[mcVersion];
  if (pinned) {
    const v = versions.find((x) => x.version_number === pinned);
    if (!v) throw new Error(`${slug}: the pinned version ${pinned} is not published for Minecraft ${mcVersion}`);
    return { version: v, pinned: true };
  }
  const releases = versions
    .filter((x) => x.version_type === "release")
    .sort((a, b) => Date.parse(b.date_published) - Date.parse(a.date_published));
  if (releases.length === 0) throw new Error(`${slug}: no release for Minecraft ${mcVersion}`);
  return { version: releases[0], pinned: false };
}

async function installMod(slug, opts, pins) {
  const present = jarsFor(opts.modsDir, slug);
  if (present.length > 0) {
    console.log(`${slug}: already installed (${present[0].n}), left as it is`);
    return;
  }
  const q = `loaders=${encodeURIComponent('["fabric"]')}&game_versions=${encodeURIComponent(JSON.stringify([opts.mcVersion]))}`;
  const versions = await getJson(`${API}/project/${encodeURIComponent(slug)}/version?${q}`);
  const { version, pinned } = chooseVersion(versions, slug, opts.mcVersion, pins);
  const file = version.files.find((f) => f.primary) || version.files[0];
  if (!file || !file.hashes?.sha512) throw new Error(`${slug}: ${version.version_number} has no file with a SHA-512`);
  if (!/^[A-Za-z0-9._+-]+\.jar$/.test(file.filename)) throw new Error(`${slug}: unexpected file name ${file.filename}`);
  console.log(`${slug}: ${version.version_number}${pinned ? "" : " (not pinned for this Minecraft version; the newest release was chosen)"}`);
  if (opts.dryRun) return;
  const res = await fetch(file.url, { headers: { "User-Agent": UA } });
  if (!res.ok) throw new Error(`${slug}: download answered ${res.status}`);
  const body = Buffer.from(await res.arrayBuffer());
  const sum = crypto.createHash("sha512").update(body).digest("hex");
  if (sum !== file.hashes.sha512) throw new Error(`${slug}: the SHA-512 of the download does not match Modrinth's; nothing was kept`);
  fs.mkdirSync(opts.modsDir, { recursive: true });
  const dest = path.join(opts.modsDir, file.filename);
  const tmp = `${dest}.part`;
  fs.writeFileSync(tmp, body);
  fs.renameSync(tmp, dest);
  console.log(`${slug}: installed ${file.filename}`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const cfg = JSON.parse(fs.readFileSync(opts.pins || path.join(__dirname, "pins.json"), "utf8"));
  const pins = {};
  for (const m of cfg.mods) pins[m.slug] = m.pin || {};
  for (const slug of cfg.requires || []) {
    if (jarsFor(opts.modsDir, slug).length === 0) throw new Error(`${slug} is required but not installed; set up the server first`);
  }
  for (const m of cfg.mods) await installMod(m.slug, opts, pins);
}

module.exports = { chooseVersion, jarsFor, parseArgs };

if (require.main === module) {
  main().catch((err) => {
    console.error(`prepare_mods: ${err.message}`);
    process.exit(1);
  });
}
