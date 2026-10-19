// The events the scripts send, the list loadVariables.js validates against,
// the README and variables.example.json must all name the same set.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "..");
const KNOWN = require(path.join(ROOT, "src", "setup", "common", "loadVariables.js")).KNOWN_WEBHOOK_EVENTS;

// webhook.sh only documents the helper; doctor.sh sends its own test event.
const SKIP_FILES = new Set(["webhook.sh", "doctor.sh"]);

function sourceFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === "api-server") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) sourceFiles(full, out);
    else if (/\.(sh|js)$/.test(entry.name) && !SKIP_FILES.has(entry.name)) out.push(full);
  }
  return out;
}

function sentEvents() {
  const found = new Map();
  const add = (name, file) => found.set(name, file);
  const patterns = [
    /\bnotify(?:_success|_error|_warning)?[ \t]+"?([a-z]+(?:_[a-z]+)+)"?/g,
    /sendWebhook\(\s*[\w.]+,\s*"([a-z_]+)"/g,
    /"notify",\s*"([a-z_]+)"/g,
  ];
  for (const file of sourceFiles(path.join(ROOT, "src"))) {
    const text = fs.readFileSync(file, "utf8");
    for (const re of patterns) for (const m of text.matchAll(re)) add(m[1], path.relative(ROOT, file));
  }
  return found;
}

test("every event a script sends is a known event", () => {
  const unknown = [...sentEvents()].filter(([name]) => !KNOWN.includes(name));
  assert.deepEqual(unknown, [], "add it to KNOWN_WEBHOOK_EVENTS and the README");
});

test("every known event is sent by some script", () => {
  const sent = sentEvents();
  assert.deepEqual(KNOWN.filter((name) => !sent.has(name)), []);
});

test("the README documents every known event", () => {
  const readme = fs.readFileSync(path.join(ROOT, "readme.md"), "utf8");
  assert.deepEqual(KNOWN.filter((name) => !readme.includes("`" + name + "`")), []);
});

test("variables.example.json lists only known events", () => {
  const example = JSON.parse(fs.readFileSync(path.join(ROOT, "variables.example.json"), "utf8"));
  assert.deepEqual(example.NOTIFICATIONS.WEBHOOK_EVENTS.filter((name) => !KNOWN.includes(name)), []);
});
