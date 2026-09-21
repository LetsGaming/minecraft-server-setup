// scripts/update/update-mod.js
//
// Update one installed mod to its latest compatible build.
//
// Usage:
//   node update-mod.js <slug> [--json]
//
// Reuses update-mods.js: `runUpdates({ only })` runs the same check, download
// and manifest-write path, restricted to a single slug. This exists because the
// dashboard's per-mod Update must touch exactly one mod, and add-mod.js refuses
// an already-installed mod by design.

const { parseArgs } = require("./lib/args");
const { runUpdates, emitJson, failWith, JSON_MODE } = require("./update-mods.js");

const cli = parseArgs({
  flags: { slug: null },
  boolFlags: ["json"],
  positional: ["slug"],
});

const slug = cli.get("slug");
if (!slug) {
  failWith("error", "Usage: node update-mod.js <slug> [--json]");
}

runUpdates({ only: slug })
  .then((summary) => {
    const failure = summary.failed.find((f) => f.slug === slug);
    if (JSON_MODE) {
      emitJson(
        failure
          ? { ok: false, slug, error: failure.error, code: "update-failed" }
          : { ok: true, ...summary },
      );
    } else if (!JSON_MODE) {
      console.log("Done.");
    }
    if (failure) process.exitCode = 1;
  })
  .catch((err) => failWith("error", err.message));
