const fs = require("fs");
const path = require("path");
const axios = require("axios");
const {
  mod_slugs
} = require("./modrinth_variables.json");

const {
  createDownloadDir,
  formatBytes,
  downloadFile,
  saveDownloadedVersion,
  isAlreadyDownloaded,
  getMinecraftVersion,
  getModLoader
} = require("./download_utils");

// ==== Config & Argument Parsing ====
const args = process.argv.slice(2);
const customDownloadDir = getDownloadDirFromArgs(args);
const modSlugs = getModSlugsFromArgs(args) || getModSlugsFromJson();

validateSetup(modSlugs);
createDownloadDir(customDownloadDir);

let processedMods = new Set();

// ==== Main Entrypoint ====
(async () => {
  const minecraftVersion = await getMinecraftVersion();
  const modLoader = getModLoader();

  if (!minecraftVersion || !modLoader) {
    console.error("Missing Minecraft version or mod loader. Please download a modpack first.");
    process.exit(1);
  }

  for (const slug of modSlugs) {
    console.log(`\nProcessing mod: ${slug}`);
    await downloadMod(slug, minecraftVersion, modLoader);
  }
})();

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
    console.error(`Mod slugs file not found: ${filePath}`);
    process.exit(1);
  }

  try {
    const content = fs.readFileSync(filePath, "utf8");
    const slugs = content
      .split(/\r?\n|,/)
      .map((slug) => slug.trim())
      .filter(Boolean);
    if (slugs.length) {
      console.log(`Using mod slugs from ${filePath}: ${slugs.join(", ")}`);
      return slugs;
    }
  } catch (err) {
    console.error(`Failed to read mod slugs file: ${err.message}`);
    process.exit(1);
  }

  return null;
}

function getModSlugsFromJson() {
  if (Array.isArray(mod_slugs) && mod_slugs.length > 0) {
    const slugs = mod_slugs.filter((id) => id && id !== "none");
    console.log(`Using mod slugs from modrinth_variables.json: ${slugs.join(", ")}`);
    return slugs;
  }

  console.error("No mod slugs provided via args or JSON.");
  process.exit(1);
}

// ==== Validation ====

function validateSetup(slugs) {
  if (!Array.isArray(slugs) || slugs.length === 0) {
    console.error("No valid mod slugs found.");
    process.exit(1);
  }
}

// ==== Core Download Logic ====
async function downloadMod(slugOrProjectId, mcVersion, modLoader) {
  if (processedMods.has(slugOrProjectId)) return;
  processedMods.add(slugOrProjectId);

  try {
    // Accept either project slug or ID
    const projectRes = await axios.get(`https://api.modrinth.com/v2/project/${slugOrProjectId}`);
    const project = projectRes.data;
    const projectSlug = project.slug;
    const projectId = project.project_id || project.id;

    const versionRes = await axios.get(
      `https://api.modrinth.com/v2/project/${projectId}/version`,
      {
        params: {
          loaders: [modLoader],
          game_versions: [mcVersion]
        }
      }
    );

    const versions = versionRes.data;
    if (!versions.length) {
      console.warn(`No compatible versions found for ${projectSlug} (MC ${mcVersion}, ${modLoader})`);
      return;
    }

    // Find the first version that actually contains both mcVersion and modLoader
    const version = versions.find(v =>
      v.game_versions.includes(mcVersion) &&
      v.loaders.includes(modLoader)
    );

    if (!version) {
      console.warn(`No version matching MC ${mcVersion} and loader ${modLoader} found for ${projectSlug}`);
      return;
    }

    // Find the primary file or fallback
    const file = version.files.find(f => f.primary || f.filename.endsWith(".jar")) || version.files[0];

    if (!file || !file.url) {
      console.warn(`No downloadable file found for ${projectSlug}`);
      return;
    }

    if (isAlreadyDownloaded("mods", projectSlug, version.id)) {
      console.log(`Mod ${projectSlug} (version ${version.id}) already downloaded. Skipping.`);
    } else {
      const outputPath = path.join(customDownloadDir, file.filename);
      console.log(`Downloading ${file.filename} (${formatBytes(file.size || 0)})...`);

      await downloadFile(file.url, outputPath, file.size || 0);
      saveDownloadedVersion("mods", projectSlug, version.id, modLoader, mcVersion);
    }

    // ==== Process dependencies ====
    const dependencies = version.dependencies || [];
    for (const dep of dependencies) {
      if (dep.dependency_type === "required" && dep.project_id) {
        console.log(`→ Fetching required dependency: ${dep.project_id}`);
        await downloadMod(dep.project_id, mcVersion, modLoader);
      }
    }
  } catch (err) {
    console.error(`Error processing mod ${slugOrProjectId}:`, err.response?.data || err.message);
  }
}
