// scripts/update/lib/download.js
//
// Downloading files named by a remote API (Modrinth, Mojang) onto the server.
// Nothing the remote says is trusted: filenames are decoded then reduced to a
// plain basename, bodies are size-capped, hashes are verified when the API
// provides them, and a partial or rejected download never leaves a file
// behind.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { Transform } = require("stream");
const { pipeline } = require("stream/promises");
const axios = require("axios");

const DEFAULT_MAX_BYTES = 512 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_DEADLINE_MS = 10 * 60 * 1000;

/**
 * The filename a download URL names, safe to join onto a directory.
 *
 * The final path segment is percent-decoded first and only then checked, so an
 * encoded separator ("%2F..%2Fx.jar") cannot decode into a path after the
 * check. Throws for anything that is not a single plain filename.
 *
 * @param {string} url
 * @returns {string}
 */
function safeFilenameFromUrl(url) {
  const lastSegment = new URL(url).pathname.split("/").pop() ?? "";
  let name;
  try {
    name = decodeURIComponent(lastSegment);
  } catch {
    throw new Error(`Refusing malformed filename in download URL: ${url}`);
  }
  assertPlainFilename(name);
  return name;
}

/** Throws unless `name` is one plain file name (no separators, no dot names). */
function assertPlainFilename(name) {
  if (
    !name ||
    name === "." ||
    name === ".." ||
    name.includes("/") ||
    name.includes("\\") ||
    name.includes("\0") ||
    name.length > 255 ||
    path.basename(name) !== name
  ) {
    throw new Error(`Refusing unsafe filename: ${JSON.stringify(name)}`);
  }
}

function rmQuiet(file) {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    /* best effort */
  }
}

/**
 * Download `url` into `tempPath`, verifying size and hashes. On any failure
 * `tempPath` is removed and the error is thrown; on success the verified file
 * sits at `tempPath` for the caller to move into place.
 *
 * @param {string} url
 * @param {string} tempPath
 * @param {object} [opts]
 * @param {string} [opts.sha512]   expected hex digest
 * @param {string} [opts.sha1]     expected hex digest
 * @param {number} [opts.maxBytes]
 * @param {number} [opts.timeoutMs]    wait for the response to start
 * @param {number} [opts.deadlineMs]   whole-download limit
 * @param {(received: number, total: number) => void} [opts.onProgress]
 * @returns {Promise<{ bytes: number }>}
 */
async function downloadToTemp(url, tempPath, opts = {}) {
  const {
    sha512,
    sha1,
    maxBytes = DEFAULT_MAX_BYTES,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    deadlineMs = DEFAULT_DEADLINE_MS,
    onProgress,
  } = opts;

  try {
    const response = await axios({
      url,
      method: "GET",
      responseType: "stream",
      timeout: timeoutMs,
      maxContentLength: maxBytes,
      maxBodyLength: maxBytes,
      signal: AbortSignal.timeout(deadlineMs),
      validateStatus: (s) => s >= 200 && s < 300,
    });

    const total = parseInt(response.headers?.["content-length"] || "0", 10);
    if (total > maxBytes) {
      response.data.destroy();
      throw new Error(`Download is ${total} bytes, over the ${maxBytes} byte limit.`);
    }

    const hash512 = sha512 ? crypto.createHash("sha512") : null;
    const hash1 = sha1 ? crypto.createHash("sha1") : null;
    let received = 0;

    const meter = new Transform({
      transform(chunk, _enc, cb) {
        received += chunk.length;
        if (received > maxBytes) {
          cb(new Error(`Download exceeded the ${maxBytes} byte limit.`));
          return;
        }
        hash512?.update(chunk);
        hash1?.update(chunk);
        if (onProgress) onProgress(received, total);
        cb(null, chunk);
      },
    });

    await pipeline(response.data, meter, fs.createWriteStream(tempPath));

    if (hash512 && hash512.digest("hex") !== sha512.toLowerCase()) {
      throw new Error("Downloaded file failed sha512 verification.");
    }
    if (hash1 && hash1.digest("hex") !== sha1.toLowerCase()) {
      throw new Error("Downloaded file failed sha1 verification.");
    }
    return { bytes: received };
  } catch (err) {
    rmQuiet(tempPath);
    throw err;
  }
}

/** Download to `${finalPath}.tmp`, verify, then rename onto `finalPath`. */
async function downloadVerified(url, finalPath, opts = {}) {
  const tempPath = `${finalPath}.tmp`;
  const result = await downloadToTemp(url, tempPath, opts);
  try {
    fs.renameSync(tempPath, finalPath);
  } catch (err) {
    rmQuiet(tempPath);
    throw err;
  }
  return result;
}

module.exports = {
  safeFilenameFromUrl,
  assertPlainFilename,
  downloadToTemp,
  downloadVerified,
};
