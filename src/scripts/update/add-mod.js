// scripts/update/add-mod.js
//
// Downloads a single mod from Modrinth, installs it into the server's mods
// directory, and registers it in downloaded_versions.json.
// Required dependencies are installed automatically.
//
// Usage:
//   node add-mod.js <slug-or-project-id> [--mcVersion=1.21.4] [--modLoader=fabric] [--versionId=abc123]
//
// mcVersion and modLoader fall back to the values in downloaded_versions.json
// when not supplied. versionId pins the install to that exact Modrinth
// build instead of resolving the newest compatible one.

const fs = require("fs");
const path = require("path");
const axios = require("axios");
// S-015: a half-open connection must not hang this script forever, least of
// all during an upgrade, with the server stopped and the lock held. File
// downloads set their own deadlines (lib/download.js).
axios.defaults.timeout = axios.defaults.timeout || 30_000;

// ── Paths ─────────────────────────────────────────────────────────────────────

const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "common",
  "downloaded_versions.json",
);

// ── CLI args ──────────────────────────────────────────────────────────────────

// Usage:
//   node add-mod.js <slug> [mcVersion] [modLoader]
//         [--slug=<slug>] [--mcVersion=<ver>] [--modLoader=<loader>]
//
//   slug       Modrinth slug or project ID — positional or --slug=.
//   mcVersion  Target MC version. Falls back to downloaded_versions.json.
//   modLoader  Mod loader (e.g. fabric). Falls back to downloaded_versions.json.
// Serialized with other mod changes and with restore, rollback and upgrade
// (S-024): re-runs this script under the instance's operation lock.
require("./lib/opLock").guardModOperation();
const { readManifest, writeManifest } = require("./lib/manifest");
const { parseArgs } = require("./lib/args");
const { loadVariables } = require("./lib/variables");
const { createJsonMode } = require("./lib/json-mode");
const { safeFilenameFromUrl, downloadVerified, fileMatchesHash } = require("./lib/download");
const { pickVersion } = require("./lib/versions");
const { isXaeroSlug, applyXaeroConfig } = require("./lib/xaero");

const cliArgs = parseArgs({
  flags: { slug: null, mcVersion: null, modLoader: null, versionId: null },
  positional: ["slug", "mcVersion", "modLoader"],
});

// ── Machine-readable mode ─────────────────────────────────────────────────
//
// With --json the wrapper drives this script and needs one JSON object on
// stdout, not the human log. Rather than thread a result through every exit
// site, the human channels are silenced and, at the bottom, main() runs with
// process.exit intercepted so any exit becomes one emitted object.
const JSON_MODE = cliArgs.bool("json");
const jsonMode = createJsonMode(JSON_MODE, {
  captureErrors: true,
  silenceStdoutWrite: true,
});
const emitJson = jsonMode.emit;
function classifyError(msg) {
  if (!msg) return "error";
  if (/not found on modrinth/i.test(msg)) return "not-found";
  if (/no compatible version|no version matching/i.test(msg))
    return "no-compatible-version";
  if (/downloaded_versions\.json/i.test(msg)) return "manifest";
  return "error";
}

const slug = cliArgs.get("slug");

if (!slug) {
  if (JSON_MODE) {
    emitJson({ ok: false, error: "Missing mod slug", code: "error" });
  } else {
    console.error(
      "Usage: node add-mod.js <slug-or-project-id> [--slug=...] [--mcVersion=...] [--modLoader=...]",
    );
  }
  process.exit(1);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function readVersionsFile() {
  try {
    return readManifest(downloadedVersionsPath);
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}

function writeVersionsFile(data) {
  writeManifest(downloadedVersionsPath, data);
}

/**
 * Download a Modrinth file object to `targetPath`: through a temp file, size
 * capped, and verified against the sha512 Modrinth publishes.
 */
async function downloadFile(file, targetPath) {
  let announced = false;
  await downloadVerified(file.url, targetPath, {
    sha512: file.hashes?.sha512,
    sha1: file.hashes?.sha1,
    onProgress(received, total) {
      if (!total) return;
      announced = true;
      process.stdout.write(`  Downloading... ${((received / total) * 100).toFixed(1)}%\r`);
    },
  });
  if (announced) process.stdout.write("\n");
}

// ── Modrinth API ──────────────────────────────────────────────────────────────

async function resolveProject(slugOrId) {
  try {
    const res = await axios.get(
      `https://api.modrinth.com/v2/project/${encodeURIComponent(slugOrId)}`,
    );
    return res.data;
  } catch (err) {
    if (err.response?.status === 404) {
      console.error(`Mod not found on Modrinth: "${slugOrId}"`);
    } else {
      console.error(
        `Modrinth API error: ${err.response?.data?.description ?? err.message}`,
      );
    }
    process.exit(1);
  }
}

async function fetchCompatibleVersion(projectId, mcVersion, modLoader) {
  const res = await axios.get(
    `https://api.modrinth.com/v2/project/${encodeURIComponent(projectId)}/version`,
    { params: { game_versions: [mcVersion], loaders: [modLoader] } },
  );

  // The newest release; a beta or alpha only when the mod has no release.
  return pickVersion(res.data, mcVersion, modLoader);
}

async function fetchVersion(versionId) {
  try {
    const res = await axios.get(
      `https://api.modrinth.com/v2/version/${encodeURIComponent(versionId)}`,
    );
    return res.data;
  } catch (err) {
    if (err.response?.status === 404) {
      console.error(`Version not found on Modrinth: "${versionId}"`);
    } else {
      console.error(
        `Modrinth API error: ${err.response?.data?.description ?? err.message}`,
      );
    }
    process.exit(1);
  }
}

// ── Core install logic ────────────────────────────────────────────────────────

/**
 * Download and register a single mod (by slug or project ID).
 * Skips silently if already registered. Does NOT recurse into deps —
 * the caller is responsible for iterating dependencies.
 *
 * @param {string}  slugOrId          Modrinth slug or project ID.
 * @param {string}  mcVersion
 * @param {string}  modLoader
 * @param {string}  modsDir
 * @param {object}  downloadedVersions  Mutated in-place; caller must persist.
 * @param {string}  [indent=""]         Prefix for log lines (used for deps).
 * @param {string}  [versionId]         Pin to this exact build instead of
 *                                      resolving the newest compatible one.
 * @returns {object|null}  The Modrinth version object if freshly installed,
 *                         { filenameUpdated: true } if an existing null-filename
 *                         entry was patched, or null if already fully registered.
 */
async function installMod(
  slugOrId,
  mcVersion,
  modLoader,
  modsDir,
  downloadedVersions,
  indent = "",
  versionId,
) {
  // Resolve canonical slug so we can key into downloadedVersions.mods
  const project = await resolveProject(slugOrId);
  const projectId = project.id;
  const canonicalSlug = project.slug;

  // Check by canonical slug (normal case) AND by raw project ID (handles legacy
  // entries that were registered under their project ID instead of their slug).
  const existing =
    downloadedVersions.mods[canonicalSlug] ??
    downloadedVersions.mods[projectId];
  if (existing) {
    // Already fully registered — nothing to do.
    if (existing.filename !== null) {
      console.log(
        `${indent}Skipping "${canonicalSlug}" — already registered (${existing.versionId}).`,
      );
      return { alreadyRegistered: true, versionId: existing.versionId };
    }

    // Registered but filename is missing — fetch the known version, download
    // the file if needed, and patch the entry in place.
    console.log(
      `${indent}Updating filename for "${canonicalSlug}" (${existing.versionId})...`,
    );
    const knownVersion = await fetchVersion(existing.versionId);
    const primaryFile =
      knownVersion.files.find((f) => f.primary) ?? knownVersion.files[0];
    if (!primaryFile?.url) {
      console.error(
        `${indent}No downloadable file found for "${canonicalSlug}" version ${existing.versionId}.`,
      );
      process.exit(1);
    }

    const filename = safeFilenameFromUrl(primaryFile.url);
    const targetPath = path.join(modsDir, filename);

    console.log(`${indent}File      : ${filename}`);

    if (fs.existsSync(targetPath) && fileMatchesHash(targetPath, primaryFile.hashes)) {
      console.log(`${indent}File already present in mods dir and matches its published checksum.`);
    } else {
      process.stdout.write(indent);
      await downloadFile(primaryFile, targetPath);
      console.log(`${indent}Downloaded: ${filename}`);
    }

    existing.filename = filename;
    writeVersionsFile(downloadedVersions);
    console.log(`${indent}Updated filename for "${canonicalSlug}" in downloaded_versions.json.`);
    return { filenameUpdated: true, dependencies: knownVersion.dependencies ?? [] };
  }

  const version = versionId
    ? await fetchVersion(versionId)
    : await fetchCompatibleVersion(projectId, mcVersion, modLoader);
  if (!version) {
    console.error(
      versionId
        ? `${indent}Version "${versionId}" not found for "${canonicalSlug}".`
        : `${indent}No compatible version found for "${canonicalSlug}" (MC ${mcVersion}, ${modLoader}).`,
    );
    process.exit(1);
  }

  const primaryFile = version.files.find((f) => f.primary) ?? version.files[0];
  if (!primaryFile?.url) {
    console.error(
      `${indent}No downloadable file found for "${canonicalSlug}" version ${version.id}.`,
    );
    process.exit(1);
  }

  const filename = safeFilenameFromUrl(primaryFile.url);
  const targetPath = path.join(modsDir, filename);

  console.log(`${indent}Version   : ${version.name} (${version.id})`);
  console.log(`${indent}File      : ${filename}`);
  console.log(`${indent}Published : ${version.date_published}`);

  // A file with that name may be anything; it is registered only when it is the
  // build Modrinth lists, otherwise it is replaced by a verified download.
  if (fs.existsSync(targetPath) && fileMatchesHash(targetPath, primaryFile.hashes)) {
    console.log(`${indent}File already present in mods dir — skipping download.`);
  } else {
    process.stdout.write(indent); // align the progress line with the rest
    await downloadFile(primaryFile, targetPath);
    console.log(`${indent}Downloaded: ${filename}`);
  }

  downloadedVersions.mods[canonicalSlug] = {
    versionId: version.id,
    filename,
  };
  writeVersionsFile(downloadedVersions);

  console.log(`${indent}Registered "${canonicalSlug}" in downloaded_versions.json.`);
  if (isXaeroSlug(canonicalSlug)) {
    await applyXaeroConfig(variablesPath, path.dirname(modsDir));
  }

  return version;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  // ── Resolve config ──────────────────────────────────────────────────────────
  const vars = loadVariables(variablesPath, { optional: true });
  const downloadedVersions = readVersionsFile();
  downloadedVersions.mods ??= {};

  const versionId = cliArgs.get("versionId");
  const mcVersion = cliArgs.get("mcVersion") ?? downloadedVersions.gameVersion;
  const modLoader = cliArgs.get("modLoader") ?? downloadedVersions.modLoader;

  // versionId pins the exact build, so resolving by mcVersion/modLoader is
  // skipped for the requested mod — but dependencies still need both to
  // resolve their own compatible builds.
  if (!versionId && !mcVersion) {
    console.error(
      "Minecraft version unknown. Pass --mcVersion=... or ensure gameVersion is set in downloaded_versions.json.",
    );
    process.exit(1);
  }
  if (!versionId && !modLoader) {
    console.error(
      "Mod loader unknown. Pass --modLoader=... or ensure modLoader is set in downloaded_versions.json.",
    );
    process.exit(1);
  }

  const serverPath = vars.SERVER_PATH;
  if (!serverPath || !fs.existsSync(serverPath)) {
    console.error(`Invalid SERVER_PATH: "${serverPath}"`);
    process.exit(1);
  }

  const modsDir = path.join(serverPath, "mods");
  fs.mkdirSync(modsDir, { recursive: true });

  console.log(`\nAdding mod: ${slug}`);
  console.log(`  MC version : ${mcVersion ?? "(pinned to versionId)"}`);
  console.log(`  Mod loader : ${modLoader ?? "(pinned to versionId)"}`);
  console.log(`  Mods dir   : ${modsDir}\n`);
  if (versionId) console.log(`  Version ID : ${versionId}\n`);

  // ── Install the requested mod ────────────────────────────────────────────────
  let version = await installMod(
    slug,
    mcVersion,
    modLoader,
    modsDir,
    downloadedVersions,
    "",
    versionId,
  );

  // S-023: the mod is registered before its dependencies are installed, so a
  // run that failed on a dependency left it registered without it, and every
  // later add stopped right here. An already registered mod still gets its
  // required dependencies checked and installed.
  if (version?.alreadyRegistered) {
    console.log("Checking that its required dependencies are installed...");
    try {
      version = await fetchVersion(version.versionId);
    } catch {
      version = null;
    }
    if (!version) {
      console.log("Its registered version could not be fetched; dependencies not checked.");
      process.exit(0);
    }
  }

  console.log("\nDone.\n");

  // ── Auto-install required dependencies ──────────────────────────────────────
  const required = (version.dependencies ?? []).filter(
    (d) => d.dependency_type === "required" && d.project_id,
  );

  if (!required.length) return;

  console.log(`Installing ${required.length} required dependenc${required.length === 1 ? "y" : "ies"}...\n`);

  for (const dep of required) {
    // Resolve the dep's canonical slug so we can print a human-readable name
    // and do an accurate already-registered check (mods are keyed by slug).
    let depSlug = dep.project_id;
    try {
      const depProject = await resolveProject(dep.project_id);
      depSlug = depProject.slug;
    } catch {
      // resolveProject calls process.exit on error, so this is unreachable,
      // but keep the fallback for safety.
    }

    // Skip only if already registered AND the file is known. If filename is
    // null, fall through to installMod so it can patch the entry.
    const depEntry =
      downloadedVersions.mods[depSlug] ??
      downloadedVersions.mods[dep.project_id];
    if (depEntry?.filename !== null && depEntry !== undefined) {
      console.log(`  [dep] "${depSlug}" — already registered, skipping.`);
      continue;
    }

    console.log(`  [dep] Adding: ${depSlug}`);
    await installMod(
      dep.project_id,
      mcVersion,
      modLoader,
      modsDir,
      downloadedVersions,
      "  [dep]   ",
    );
    console.log();
  }

  console.log("All dependencies installed.\n");
}

if (!JSON_MODE) {
  main().catch((err) => {
    console.error("Fatal:", err.message);
    process.exit(1);
  });
} else {
  // Intercept exits so the many `process.exit(1)` sites inside the helpers
  // become one emitted object. exit(0) is a success that had nothing to do
  // (already registered); anything else is a handled failure.
  const _realExit = process.exit.bind(process);
  process.exit = (code = 0) => {
    const e = new Error(jsonMode.lastError() || "exit");
    e.__exit = code;
    throw e;
  };
  main()
    .then(() => emitJson({ ok: true, slug }))
    .catch((e) => {
      if (e && e.__exit === 0) {
        emitJson({ ok: true, slug });
        return;
      }
      emitJson({
        ok: false,
        error: jsonMode.lastError() || e.message,
        code: classifyError(jsonMode.lastError() || e.message),
      });
      _realExit(1);
    });
}