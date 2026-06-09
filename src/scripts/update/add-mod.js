// scripts/update/add-mod.js
//
// Downloads a single mod from Modrinth, installs it into the server's mods
// directory, and registers it in downloaded_versions.json.
// Required dependencies are installed automatically.
//
// Usage:
//   node add-mod.js <slug-or-project-id> [--mcVersion=1.21.4] [--modLoader=fabric]
//
// mcVersion and modLoader fall back to the values in downloaded_versions.json
// when not supplied.

const fs = require("fs");
const path = require("path");
const axios = require("axios");

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
const { parseArgs } = require("./args");

const cliArgs = parseArgs({
  flags: { slug: null, mcVersion: null, modLoader: null },
  positional: ["slug", "mcVersion", "modLoader"],
});

const slug = cliArgs.get("slug");

if (!slug) {
  console.error(
    "Usage: node add-mod.js <slug-or-project-id> [--slug=...] [--mcVersion=...] [--modLoader=...]",
  );
  process.exit(1);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function loadVariables() {
  if (!fs.existsSync(variablesPath)) return {};
  const content = fs.readFileSync(variablesPath, "utf8");
  const vars = {};
  for (const line of content.split(/\r?\n/)) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    vars[match[1]] = value;
  }
  return vars;
}

function readVersionsFile() {
  if (!fs.existsSync(downloadedVersionsPath)) {
    console.error(
      `downloaded_versions.json not found at: ${downloadedVersionsPath}`,
    );
    process.exit(1);
  }
  try {
    return JSON.parse(fs.readFileSync(downloadedVersionsPath, "utf8"));
  } catch {
    console.error("Could not parse downloaded_versions.json.");
    process.exit(1);
  }
}

function writeVersionsFile(data) {
  const tmp = `${downloadedVersionsPath}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), "utf8");
  fs.renameSync(tmp, downloadedVersionsPath);
}

async function downloadFile(url, targetPath) {
  const response = await axios({ url, method: "GET", responseType: "stream" });
  const total = parseInt(response.headers["content-length"] || "0", 10);
  let received = 0;

  return new Promise((resolve, reject) => {
    const writer = fs.createWriteStream(targetPath);

    response.data.on("data", (chunk) => {
      received += chunk.length;
      if (total) {
        const pct = ((received / total) * 100).toFixed(1);
        process.stdout.write(`  Downloading... ${pct}%\r`);
      }
    });

    response.data.pipe(writer);
    writer.on("error", reject);
    writer.on("close", () => {
      if (total) process.stdout.write("\n");
      resolve();
    });
  });
}

// ── Modrinth API ──────────────────────────────────────────────────────────────

async function resolveProject(slugOrId) {
  try {
    const res = await axios.get(
      `https://api.modrinth.com/v2/project/${slugOrId}`,
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
    `https://api.modrinth.com/v2/project/${projectId}/version`,
    { params: { game_versions: [mcVersion], loaders: [modLoader] } },
  );

  const versions = res.data;
  if (!versions.length) return null;

  // Most recently published compatible version
  versions.sort(
    (a, b) => new Date(b.date_published) - new Date(a.date_published),
  );
  return (
    versions.find(
      (v) =>
        v.game_versions.includes(mcVersion) && v.loaders.includes(modLoader),
    ) ?? null
  );
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
 * @returns {object|null}  The Modrinth version object, or null if already registered.
 */
async function installMod(
  slugOrId,
  mcVersion,
  modLoader,
  modsDir,
  downloadedVersions,
  indent = "",
) {
  // Resolve canonical slug so we can key into downloadedVersions.mods
  const project = await resolveProject(slugOrId);
  const projectId = project.id;
  const canonicalSlug = project.slug;

  if (downloadedVersions.mods[canonicalSlug]) {
    const existing = downloadedVersions.mods[canonicalSlug];
    console.log(
      `${indent}Skipping "${canonicalSlug}" — already registered (${existing.versionId}).`,
    );
    return null;
  }

  const version = await fetchCompatibleVersion(projectId, mcVersion, modLoader);
  if (!version) {
    console.error(
      `${indent}No compatible version found for "${canonicalSlug}" (MC ${mcVersion}, ${modLoader}).`,
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

  const filename = decodeURIComponent(
    path.basename(new URL(primaryFile.url).pathname),
  );
  const targetPath = path.join(modsDir, filename);
  const tempPath = `${targetPath}.tmp`;

  console.log(`${indent}Version   : ${version.name} (${version.id})`);
  console.log(`${indent}File      : ${filename}`);
  console.log(`${indent}Published : ${version.date_published}`);

  if (fs.existsSync(targetPath)) {
    console.log(`${indent}File already present in mods dir — skipping download.`);
  } else {
    process.stdout.write(indent); // align the progress line with the rest
    await downloadFile(primaryFile.url, tempPath);
    fs.renameSync(tempPath, targetPath);
    console.log(`${indent}Downloaded: ${filename}`);
  }

  downloadedVersions.mods[canonicalSlug] = {
    versionId: version.id,
    filename,
  };
  writeVersionsFile(downloadedVersions);

  console.log(`${indent}Registered "${canonicalSlug}" in downloaded_versions.json.`);

  return version;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  // ── Resolve config ──────────────────────────────────────────────────────────
  const vars = loadVariables();
  const downloadedVersions = readVersionsFile();
  downloadedVersions.mods ??= {};

  const mcVersion = cliArgs.get("mcVersion") ?? downloadedVersions.gameVersion;
  const modLoader = cliArgs.get("modLoader") ?? downloadedVersions.modLoader;

  if (!mcVersion) {
    console.error(
      "Minecraft version unknown. Pass --mcVersion=... or ensure gameVersion is set in downloaded_versions.json.",
    );
    process.exit(1);
  }
  if (!modLoader) {
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
  console.log(`  MC version : ${mcVersion}`);
  console.log(`  Mod loader : ${modLoader}`);
  console.log(`  Mods dir   : ${modsDir}\n`);

  // ── Install the requested mod ────────────────────────────────────────────────
  const version = await installMod(
    slug,
    mcVersion,
    modLoader,
    modsDir,
    downloadedVersions,
  );

  if (!version) {
    // Was already registered — installMod printed a message.
    console.log(
      "Remove it from downloaded_versions.json first if you want to re-add it.",
    );
    process.exit(0);
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

    if (downloadedVersions.mods[depSlug]) {
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

main().catch((err) => {
  console.error("Fatal:", err.message);
  process.exit(1);
});