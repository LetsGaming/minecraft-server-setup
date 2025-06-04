const fs = require("fs");
const path = require("path");
const axios = require("axios");

// Parse CLI args for --json flag
const useJsonOutput = process.argv.includes("--json");

// Load the downloaded versions JSON
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "common",
  "downloaded_versions.json"
);
if (!fs.existsSync(downloadedVersionsPath)) {
  console.error("downloaded_versions.json not found.");
  process.exit(1);
}

const downloadedVersions = JSON.parse(
  fs.readFileSync(downloadedVersionsPath, "utf8")
);

// Extract game and mod loader versions
const mcVersion = downloadedVersions.gameVersion;
const modLoader = downloadedVersions.modLoader;
const mods = downloadedVersions.mods || {};

if (!mcVersion || !modLoader) {
  console.error(
    "Minecraft version or mod loader missing in downloaded_versions.json"
  );
  process.exit(1);
}

async function checkModUpdate(slug, currentVersionId) {
  try {
    // Get project info to confirm slug
    const projectRes = await axios.get(
      `https://api.modrinth.com/v2/project/${slug}`
    );
    const project = projectRes.data;
    const projectId = project.project_id || project.id;

    // Get versions filtered by MC version and mod loader
    const versionRes = await axios.get(
      `https://api.modrinth.com/v2/project/${projectId}/version`,
      {
        params: {
          game_versions: [mcVersion],
          loaders: [modLoader],
        },
      }
    );
    const versions = versionRes.data;

    if (!versions.length) {
      if (!useJsonOutput) {
        console.log(
          `No compatible versions found for mod '${slug}' on MC ${mcVersion} with loader ${modLoader}`
        );
      }
      return {
        slug,
        status: "no_versions",
        message: `No compatible versions found for MC ${mcVersion} with loader ${modLoader}`,
      };
    }

    // Sort versions descending by date published (just to be safe)
    versions.sort(
      (a, b) => new Date(b.date_published) - new Date(a.date_published)
    );

    // Find the latest version that actually includes both mcVersion and modLoader
    const latestVersion = versions.find(
      (v) =>
        v.game_versions.includes(mcVersion) && v.loaders.includes(modLoader)
    );

    if (!latestVersion) {
      if (!useJsonOutput) {
        console.log(
          `No version matching MC ${mcVersion} and loader ${modLoader} found for mod '${slug}'.`
        );
      }
      return {
        slug,
        status: "no_matching_version",
        message: `No version matching MC ${mcVersion} and loader ${modLoader} found`,
      };
    }

    const latestVersionId = latestVersion.id;

    if (currentVersionId === latestVersionId) {
      if (!useJsonOutput) {
        console.log(
          `Mod '${slug}' is up to date (version ID: ${currentVersionId})`
        );
      }
      return {
        slug,
        status: "up_to_date",
        currentVersionId,
      };
    } else {
      if (!useJsonOutput) {
        console.log(`Update available for mod '${slug}':`);
        console.log(`  Current version ID: ${currentVersionId}`);
        console.log(`  Latest version ID : ${latestVersionId}`);
        console.log(`  Latest version name: ${latestVersion.name}`);
        console.log(`  Published on: ${latestVersion.date_published}`);
        console.log(`  Download URL: ${latestVersion.files[0]?.url || "N/A"}`);
      }
      return {
        slug,
        status: "update_available",
        currentVersionId,
        latestVersionId,
        latestVersionName: latestVersion.name,
        datePublished: latestVersion.date_published,
        downloadUrl: latestVersion.files[0]?.url || null,
      };
    }
  } catch (err) {
    const errMsg = err.response?.data || err.message;
    if (!useJsonOutput) {
      console.error(`Failed to check update for mod '${slug}':`, errMsg);
    }
    return {
      slug,
      status: "error",
      error: errMsg,
    };
  }
}

async function main() {
  if (!useJsonOutput) {
    console.log(
      `Checking updates for Minecraft version ${mcVersion} with mod loader ${modLoader}\n`
    );
  }

  const results = [];
  for (const [slug, currentVersionId] of Object.entries(mods)) {
    // eslint-disable-next-line no-await-in-loop
    const result = await checkModUpdate(slug, currentVersionId);
    results.push(result);
  }

  if (useJsonOutput) {
    // Output JSON array for easy parsing by other scripts
    console.log(JSON.stringify({ mcVersion, modLoader, results }, null, 2));
  }
}

main();
