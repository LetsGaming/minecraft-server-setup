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

/** Throws unless a download URL is https. */
function assertHttps(url) {
  const protocol = new URL(url).protocol;
  if (protocol !== "https:") throw new Error(`Refusing a ${protocol.replace(":", "")} download: ${url}`);
}

/** axios beforeRedirect hook: a redirect may not leave https, whoever sends it. */
function httpsOnlyRedirect(options) {
  if (options.protocol !== "https:") {
    throw new Error(`Refusing a redirect to ${String(options.protocol).replace(":", "")}://${options.hostname ?? ""}`);
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
    assertHttps(url);
    const response = await axios({
      url,
      method: "GET",
      responseType: "stream",
      timeout: timeoutMs,
      maxContentLength: maxBytes,
      maxBodyLength: maxBytes,
      maxRedirects: 5,
      beforeRedirect: httpsOnlyRedirect,
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

    // A leftover file or link at the temp path is removed, never written through:
    // "wx" fails if something is there again by the time the file is created.
    rmQuiet(tempPath);
    await pipeline(response.data, meter, fs.createWriteStream(tempPath, { flags: "wx", mode: 0o644 }));

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

/**
 * True when the file at `file` has the digest a remote API published for it.
 * False when the file cannot be read or when no digest was published: a file
 * nobody can vouch for is not one to register as installed.
 *
 * @param {string} file
 * @param {{sha512?: string, sha1?: string}} hashes  expected hex digests
 */
function fileMatchesHash(file, { sha512, sha1 } = {}) {
  const algo = sha512 ? "sha512" : sha1 ? "sha1" : null;
  if (!algo) return false;
  try {
    const digest = crypto.createHash(algo).update(fs.readFileSync(file)).digest("hex");
    return digest === (algo === "sha512" ? sha512 : sha1).toLowerCase();
  } catch {
    return false;
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

/**
 * Download an artifact from a Maven repository, verified against the checksum
 * the repository publishes next to it (S-021): `.sha512` when there is one,
 * else `.sha1`. Fails closed when neither can be read, because the file is
 * about to be run (the Fabric installer is executed with java -jar).
 */
async function downloadMavenVerified(url, finalPath, opts = {}) {
  for (const algo of ["sha512", "sha1"]) {
    let text;
    try {
      const res = await axios.get(`${url}.${algo}`, {
        responseType: "text",
        timeout: DEFAULT_TIMEOUT_MS,
        maxContentLength: 4096,
        validateStatus: (s) => s === 200,
      });
      text = String(res.data);
    } catch {
      continue;
    }
    const hex = text.trim().split(/\s+/)[0]?.toLowerCase() ?? "";
    const length = algo === "sha512" ? 128 : 40;
    if (!new RegExp(`^[0-9a-f]{${length}}$`).test(hex)) continue;
    return downloadVerified(url, finalPath, { ...opts, [algo]: hex });
  }
  throw new Error(`No published checksum for ${url}; refusing to use it unverified.`);
}

module.exports = {
  safeFilenameFromUrl,
  assertPlainFilename,
  assertHttps,
  httpsOnlyRedirect,
  downloadToTemp,
  downloadVerified,
  fileMatchesHash,
  downloadMavenVerified,
};
