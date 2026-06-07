const fs = require("fs");
const path = require("path");
const axios = require("axios");

const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
  isAlreadyDownloaded,
  getMinecraftVersion,
  getModLoader,
} = require("./download_utils");

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
    console.error(`Mod IDs file not found: ${filePath}`);
    process.exit(1);
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
    console.error(`Failed to read mod IDs file: ${err.message}`);
    process.exit(1);
  }

  return null;
}

function getModSlugsFromJson() {
  try {
    const { mod_ids } = require("./json/modrinth_variables.json");
    if (Array.isArray(mod_ids) && mod_ids.length > 0) {
      const ids = mod_ids.filter((id) => id && id !== "none");
      if (ids.length > 0) {
        console.log(
          `Using mod IDs from modrinth_variables.json: ${ids.join(", ")}`
        );
        return ids;
      }
    }
  } catch {
    // continue
  }

  console.error("No mod IDs provided via args or JSON.");
  process.exit(1);
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
    console.error("Could not determine Minecraft version. Provide --mcVersion=... or ensure a modpack has been downloaded.");
    process.exit(1);
  }

  if (!loader) {
    console.error("Could not determine mod loader. Provide --modLoader=... or ensure a modpack has been downloaded.");
    process.exit(1);
  }

  if (!Array.isArray(ids) || ids.length === 0) {
    console.error("No valid mod IDs found.");
    process.exit(1);
  }
}

// ==== Core Download Logic ====

const processedMods = new Set();

async function downloadModrinthProject(projectId, mcVersion, loader, downloadDir) {
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
    const outputPath = path.join(downloadDir, fileName);
    console.log(`Downloading ${fileName} to ${downloadDir}...`);
    await downloadFile(file.url, outputPath, file.size || null);
    saveDownloadedVersion("mods", projectId, versionId);

    // Handle dependencies
    const dependencies = compatibleVersion.dependencies || [];
    for (const dep of dependencies) {
      if (dep.project_id && dep.dependency_type === "required") {
        console.log(`→ Found dependency: ${dep.project_id}`);
        await downloadModrinthProject(dep.project_id, mcVersion, loader, downloadDir);
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

// ==== Main Entrypoint ====

(async () => {
  const args = process.argv.slice(2);
  const downloadDir = getDownloadDirFromArgs(args);
  const modSlugs = getModSlugsFromArgs(args) || getModSlugsFromJson();

  // Properly await async version/loader resolution
  let minecraftVersion = getMinecraftVersionFromArgs(args);
  if (!minecraftVersion) {
    minecraftVersion = await getMinecraftVersion();
  }

  let modLoader = getModLoaderFromArgs(args);
  if (!modLoader) {
    modLoader = await getModLoader();
  }

  validateSetup(minecraftVersion, modLoader, modSlugs);
  createDownloadDir(downloadDir);

  for (const projectId of modSlugs) {
    console.log(`\nProcessing project ID: ${projectId}`);
    await downloadModrinthProject(projectId, minecraftVersion, modLoader, downloadDir);
  }
})();
