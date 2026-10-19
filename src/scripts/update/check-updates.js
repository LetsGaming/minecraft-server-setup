const fs = require("fs");
const path = require("path");
const axios = require("axios");
// S-015: a half-open connection must not hang this script forever, least of
// all during an upgrade, with the server stopped and the lock held. File
// downloads set their own deadlines (lib/download.js).
axios.defaults.timeout = axios.defaults.timeout || 30_000;
const { parseArgs } = require("./lib/args");
const { pickVersion, newestFirst } = require("./lib/versions");

// Usage:
//   node check-updates.js [mcVersion] [--mcVersion=<ver>] [--only=<slug>] [--json]
//
//   mcVersion  MC version to check against — positional or --mcVersion=.
//              Falls back to gameVersion in downloaded_versions.json.
//   --only     Check just this installed mod slug. A slug that is not installed
//              is reported as invalid_entry.
//   --json     Output results as a JSON blob instead of human-readable text.
const args = parseArgs({
  flags: { mcVersion: null, only: null },
  boolFlags: ["json"],
  positional: ["mcVersion"],
});

const useJsonOutput = args.bool("json");

// Load the downloaded versions JSON
const downloadedVersionsPath = path.resolve(
  __dirname,
  "..",
  "common",
  "downloaded_versions.json",
);
if (!fs.existsSync(downloadedVersionsPath)) {
  console.error("downloaded_versions.json not found.");
  process.exit(1);
}

const downloadedVersions = JSON.parse(
  fs.readFileSync(downloadedVersionsPath, "utf8"),
);

// Extract game and mod loader versions
const mcVersion = args.get("mcVersion") || downloadedVersions.gameVersion;
const modLoader = downloadedVersions.modLoader;
const mods = downloadedVersions.mods || {};

if (!mcVersion || !modLoader) {
  console.error(
    "Minecraft version or mod loader missing in downloaded_versions.json",
  );
  process.exit(1);
}

function extractVersionId(entry) {
  if (!entry) return null;

  if (typeof entry === "string") {
    return entry;
  }

  if (typeof entry === "object" && typeof entry.versionId === "string") {
    return entry.versionId;
  }

  return null;
}

async function checkModUpdate(slug, currentVersionId) {
  try {
    const projectRes = await axios.get(
      `https://api.modrinth.com/v2/project/${encodeURIComponent(slug)}`,
    );
    const project = projectRes.data;
    const projectId = project.project_id || project.id;

    const versionRes = await axios.get(
      `https://api.modrinth.com/v2/project/${encodeURIComponent(projectId)}/version`,
      {
        params: {
          game_versions: [mcVersion],
          loaders: [modLoader],
        },
      },
    );

    const versions = versionRes.data;

    if (!versions.length) {
      if (!useJsonOutput) {
        console.log(
          `No compatible versions found for mod '${slug}' on MC ${mcVersion} with loader ${modLoader}`,
        );
      }
      return {
        slug,
        status: "no_versions",
        message: `No compatible versions found for MC ${mcVersion} with loader ${modLoader}`,
      };
    }

    // The newest release; a beta or alpha only for a mod that has no release.
    const latestVersion = pickVersion(versions, mcVersion, modLoader);

    if (!latestVersion) {
      if (!useJsonOutput) {
        console.log(
          `No version matching MC ${mcVersion} and loader ${modLoader} found for mod '${slug}'.`,
        );
      }
      return {
        slug,
        status: "no_matching_version",
        message: `No version matching MC ${mcVersion} and loader ${modLoader} found`,
      };
    }

    const latestVersionId = latestVersion.id;
    const latestFile =
      latestVersion.files.find((f) => f.primary) ?? latestVersion.files[0];

    // An installed build that is newer than the preferred one (a beta of a mod
    // whose last release is older) is not something to "update" away from.
    const installed = versions.find((v) => v.id === currentVersionId);
    if (currentVersionId === latestVersionId || (installed && newestFirst(installed, latestVersion) <= 0)) {
      if (!useJsonOutput) {
        console.log(
          `Mod '${slug}' is up to date (version ID: ${currentVersionId})`,
        );
      }
      return {
        slug,
        status: "up_to_date",
        currentVersionId,
        projectId,
      };
    }

    if (!useJsonOutput) {
      console.log(`Update available for mod '${slug}':`);
      console.log(`  Current version ID: ${currentVersionId}`);
      console.log(`  Latest version ID : ${latestVersionId}`);
      console.log(`  Latest version name: ${latestVersion.name}`);
      console.log(`  Published on: ${latestVersion.date_published}`);
      console.log(`  Download URL: ${latestFile?.url || "N/A"}`);
    }

    return {
      slug,
      status: "update_available",
      currentVersionId,
      latestVersionId,
      latestVersionName: latestVersion.name,
      datePublished: latestVersion.date_published,
      downloadUrl: latestFile?.url || null,
      downloadSha512: latestFile?.hashes?.sha512 || null,
      projectId,
      // What the new build needs that this server may not have yet.
      requiredDependencies: (latestVersion.dependencies ?? [])
        .filter((d) => d.dependency_type === "required" && d.project_id)
        .map((d) => ({ projectId: d.project_id, versionId: d.version_id ?? null })),
    };
  } catch (err) {
    const raw = err.response?.data || err.message;
    const errMsg = typeof raw === "string" ? raw : JSON.stringify(raw).slice(0, 300);
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
      `Checking updates for Minecraft version ${mcVersion} with mod loader ${modLoader}\n`,
    );
  }

  const results = [];

  const only = args.get("only");
  const entries = Object.entries(mods).filter(
    ([slug]) => only === null || slug === only,
  );
  if (only !== null && entries.length === 0) {
    results.push({
      slug: only,
      status: "invalid_entry",
      message: "Mod is not installed",
    });
  }

  for (const [slug, entry] of entries) {
    const currentVersionId = extractVersionId(entry);
    if (!currentVersionId) {
      results.push({
        slug,
        status: "invalid_entry",
        message: "Missing or invalid versionId in downloaded_versions.json",
      });
      continue;
    }

    // eslint-disable-next-line no-await-in-loop
    const result = await checkModUpdate(slug, currentVersionId);
    results.push(result);
  }

  if (useJsonOutput) {
    console.log(JSON.stringify({ mcVersion, modLoader, results }, null, 2));
  }
}

main();
