const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const axios = require("axios");

// Read variables.txt and parse SERVER_PATH
function loadVariables() {
  const variablesPath = path.resolve(__dirname, "..", "common", "variables.txt");
  if (!fs.existsSync(variablesPath)) {
    throw new Error("variables.txt not found in ../common");
  }
  const content = fs.readFileSync(variablesPath, "utf8");
  const lines = content.split(/\r?\n/);
  const vars = {};
  for (const line of lines) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (match) {
      vars[match[1]] = match[2];
    }
  }
  if (!vars.SERVER_PATH) {
    throw new Error("SERVER_PATH not defined in variables.txt");
  }
  return vars;
}

// Run check-updates.js with --json and return parsed JSON
function runCheckUpdates(version) {
  return new Promise((resolve, reject) => {
    const checkUpdatesPath = path.resolve(__dirname, "check-updates.js");
    execFile("node", [checkUpdatesPath, version, "--json"], (err, stdout, stderr) => {
      if (err) {
        return reject(
          new Error(`Failed to run check-updates.js: ${stderr || err.message}`)
        );
      }
      try {
        const data = JSON.parse(stdout);
        resolve(data);
      } catch (parseErr) {
        reject(new Error("Failed to parse JSON output from check-updates.js"));
      }
    });
  });
}

// Download a file from url and save to filepath
async function downloadFile(url, filepath) {
  const writer = fs.createWriteStream(filepath);
  const response = await axios({
    url,
    method: "GET",
    responseType: "stream",
  });

  return new Promise((resolve, reject) => {
    response.data.pipe(writer);
    let error = null;
    writer.on("error", (err) => {
      error = err;
      writer.close();
      reject(err);
    });
    writer.on("close", () => {
      if (!error) resolve();
    });
  });
}

async function main() {
  try {
    const vars = loadVariables();
    const serverPath = vars.SERVER_PATH;
    if (!fs.existsSync(serverPath)) {
      throw new Error(`SERVER_PATH does not exist: ${serverPath}`);
    }
    const modsDir = path.join(serverPath, "mods");
    if (!fs.existsSync(modsDir)) {
      console.log(`Mods directory does not exist, creating: ${modsDir}`);
      fs.mkdirSync(modsDir, { recursive: true });
    }

    // Load downloaded_versions.json for updating version info
    const downloadedVersionsPath = path.resolve(__dirname, "..", "common", "downloaded_versions.json");
    if (!fs.existsSync(downloadedVersionsPath)) {
      throw new Error("downloaded_versions.json not found.");
    }
    const downloadedVersions = JSON.parse(fs.readFileSync(downloadedVersionsPath, "utf8"));

    const version = process.argv[2] || downloadedVersions.gameVersion || "latest";
    console.log("Running check-updates.js to get update info...");
    const updateData = await runCheckUpdates(version);
    const { results } = updateData;

    for (const mod of results) {
      if (mod.status !== "update_available") {
        console.log(`Skipping mod '${mod.slug}': status=${mod.status}`);
        continue;
      }

      const downloadUrl = mod.downloadUrl;
      if (!downloadUrl) {
        console.warn(`No download URL for mod '${mod.slug}', skipping.`);
        continue;
      }

      // Remove all existing mod files related to this slug
      const existingFiles = fs.readdirSync(modsDir);
      const slugLower = mod.slug.toLowerCase();

      for (const file of existingFiles) {
        if (file.toLowerCase().includes(slugLower)) {
          const filePath = path.join(modsDir, file);
          console.log(`Removing outdated mod file: ${file}`);
          fs.unlinkSync(filePath);
        }
      }

      // Determine filename from URL, decode URI components to fix %2B -> +
      const urlPath = new URL(downloadUrl).pathname;
      const encodedFilename = path.basename(urlPath);
      const filename = decodeURIComponent(encodedFilename);

      const targetPath = path.join(modsDir, filename);

      console.log(`Downloading latest version of mod '${mod.slug}'...`);
      await downloadFile(downloadUrl, targetPath);
      console.log(`Downloaded and saved to ${targetPath}`);

      // Update downloaded_versions.json for this mod
      downloadedVersions.mods[mod.slug] = mod.latestVersionId;

      // Write back updated JSON to file
      fs.writeFileSync(downloadedVersionsPath, JSON.stringify(downloadedVersions, null, 2), "utf8");
      console.log(`Updated downloaded_versions.json for mod '${mod.slug}'`);
    }

    console.log("Mod updates completed.");
  } catch (err) {
    console.error("Error updating mods:", err.message);
    process.exit(1);
  }
}

main();
