"use strict";

const cache = require("./cache");
const scan = require("./scan");

/**
 * Make sure the cache holds a current record for one region file. Used by the
 * worker pool (and usable inline): reading is the expensive part of a scan, the
 * decision over the records is cheap and stays on the calling thread.
 *
 * @param {{file: string, dimId: string, rx: number, rz: number, cacheDir: string, force?: boolean}} job
 * @returns {{hit: boolean, chunks: number}}
 */
function ensureRecord({ file, dimId, rx, rz, cacheDir, force = false }) {
  // The fingerprint is taken before the read: a file that changes in between
  // is stored under the older fingerprint and simply misses next time.
  const fp = cache.fingerprint(file);
  if (!force && cache.load(cacheDir, dimId, rx, rz, fp)) return { hit: true, chunks: 0 };
  const record = scan.readRegionRecord(file, rx, rz);
  if (!record) return { hit: false, chunks: 0 };
  cache.store(cacheDir, dimId, rx, rz, fp, record);
  let chunks = 0;
  for (let i = 0; i < record.state.length; i++) if (record.state[i] !== scan.STATE.EMPTY) chunks++;
  return { hit: false, chunks };
}

module.exports = { ensureRecord };
