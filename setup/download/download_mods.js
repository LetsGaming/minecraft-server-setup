const fs = require("fs");
const path = require("path");
const axios = require("axios");

const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
  isAlreadyDownloaded,
} = require("./download_utils");

// ==== Config & Argument Parsing ====

const args = process.argv.slice(2);
const customDownloadDir = getDownloadDirFromArgs(args);
const modSlugs = getModSlugsFromArgs(args) || getmodSlugsFromJson();
const minecraftVersion = getMinecraftVersionFromArgs(args);
const modLoader = getModLoaderFromArgs(args);

try {
  validateSetup(minecraftVersion, modLoader, modSlugs);
  createDownloadDir(customDownloadDir);

  let processedMods = new Set();

  // ==== Main Entrypoint ====
  (async () => {
    for (const projectId of modSlugs) {
      console.log(`\nProcessing project ID: ${projectId}`);
      await downloadModrinthProject(projectId, minecraftVersion, modLoader, processedMods);
    }
  })();
} catch (err) {
  console.error("Script aborted:", err.message);
  // only exit this script’s execution, no process.exit
}

// ==== Argument Helpers ====

function getDownloadDirFromArgs(args) {
  const arg = args.find((a) => a.startsWith("--downloadDir="));
  return arg
    ? path.resolve(arg.split("=")[1])
    : path.join(__dirname, "temp", "mods");
}

function getModSlugsFromArgs(args) {
  const fileArg = args.find((a) => a.startsWith("--modSlugsFile="));
  if (!fileArg) return null;

  const filePath = path.resolve(fileArg.split("=")[1]);
  if (!fs.existsSync(filePath)) {
    throw new Error(`Mod IDs file not found: ${filePath}`);
  }

  try {
    const content = fs.readFileSync(filePath, "utf8");
    const ids = content
      .split(/\r?\n|,/)
      .map((id) => id.trim())
      .filter((id) => id.length > 0);
    if (ids.length) {
      console.log(`Using mod IDs from ${filePath}: ${ids.join(", ")}`);
      return ids;
    }
  } catch (err) {
    throw new Error(`Failed to read mod IDs file: ${err.message}`);
  }

  return null;
}

function getmodSlugsFromJson() {
  try {
    const { mod_ids } = require("./json/modrinth_variables.json");
    if (Array.isArray(mod_ids) && mod_ids.length > 0) {
      const ids = mod_ids.filter((id) => id && id !== "none");
      console.log(
        `Using mod IDs from modrinth_variables.json: ${ids.join(", ")}`
      );
      return ids;
    }
  } catch {
    // continue
  }

  throw new Error("No mod IDs provided via args or JSON.");
}

function getMinecraftVersionFromArgs(args) {
  const arg = args.find((a) => a.startsWith("--mcVersion="));
  return arg ? arg.split("=")[1] : null;
}

function getModLoaderFromArgs(args) {
  const arg = args.find((a) => a.startsWith("--modLoader="));
  return arg ? arg.split("=")[1].toLowerCase() : null;
}

// ==== Validation ====

function validateSetup(mcVersion, loader, ids) {
  if (!mcVersion) {
    throw new Error("Missing required argument: --mcVersion=...");
  }

  if (!loader) {
    throw new Error("Missing required argument: --modLoader=...");
  }

  if (!Array.isArray(ids) || ids.length === 0) {
    throw new Error("No valid mod IDs found.");
  }
}

// ==== Core Download Logic ====

async function downloadModrinthProject(projectId, mcVersion, loader, processedMods) {
  if (processedMods.has(projectId)) return;
  processedMods.add(projectId);

  try {
    const versions = await fetchProjectVersions(projectId);
    const compatibleVersion = selectCompatibleVersion(
      versions,
      mcVersion,
      loader
    );

    if (!compatibleVersion) {
      console.warn(
        `No compatible version for ${projectId} (${mcVersion}, ${loader})`
      );
      return;
    }

    const versionId = compatibleVersion.id;
    if (isAlreadyDownloaded("mods", projectId, versionId)) {
      console.log(
        `Project ${projectId} (version ${versionId}) already downloaded. Skipping.`
      );
      return;
    }

    const file =
      compatibleVersion.files.find((f) => f.primary) ||
      compatibleVersion.files[0];
    if (!file || !file.url) {
      console.warn(`No downloadable file found for ${projectId}`);
      return;
    }

    const fileName = file.filename;
    const outputPath = path.join(customDownloadDir, fileName);
    console.log(`Downloading ${fileName} to ${customDownloadDir}...`);
    await downloadFile(file.url, outputPath, file.size || null);
    saveDownloadedVersion("mods", projectId, versionId);

    // Handle dependencies
    const dependencies = compatibleVersion.dependencies || [];
    for (const dep of dependencies) {
      if (dep.project_id && dep.required) {
        console.log(`→ Found dependency: ${dep.project_id}`);
        await downloadModrinthProject(dep.project_id, mcVersion, loader, processedMods);
      }
    }
  } catch (err) {
    console.error(
      `Error processing ${projectId}:`,
      err.response?.data || err.message
    );
  }
}

async function fetchProjectVersions(projectId) {
  const url = `https://api.modrinth.com/v2/project/${projectId}/version`;
  const resp = await axios.get(url);
  return resp.data || [];
}

function selectCompatibleVersion(versions, mcVersion, loader) {
  return versions.find(
    (v) =>
      v.game_versions.includes(mcVersion) &&
      v.loaders.includes(loader.toLowerCase())
  );
}
