// scripts/update/lib/jars.js
//
// Locating installed mod jars by slug, for manifest entries that have no
// recorded filename.

const fs = require("fs");
const path = require("path");

function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Real jar files in `dir` whose name carries `slug` as a whole token.
 * Symlinks and non-files are ignored. A missing directory yields [].
 *
 * @param {string} dir
 * @param {string} slug
 * @param {string} [excludeFilename]  A filename to leave out of the result.
 * @returns {{ file: string, fullPath: string }[]}
 */
function detectInstalledJars(dir, slug, excludeFilename) {
  if (!fs.existsSync(dir)) return [];
  const slugRegex = new RegExp(
    `(^|[-_.])${escapeRegex(slug)}([-.+_]|$).*\\.jar$`,
    "i",
  );
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".jar") && f !== excludeFilename)
    .filter((f) => slugRegex.test(f))
    .map((file) => ({ file, fullPath: path.join(dir, file) }))
    .filter(({ fullPath }) => {
      try {
        const stat = fs.lstatSync(fullPath);
        return stat.isFile() && !stat.isSymbolicLink();
      } catch {
        return false;
      }
    });
}

module.exports = { escapeRegex, detectInstalledJars };
