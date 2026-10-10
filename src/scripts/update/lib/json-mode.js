// scripts/update/lib/json-mode.js
//
// The wrapper drives the update scripts with --json and needs exactly one
// JSON object on stdout. In JSON mode the human channels are silenced so
// nothing else reaches stdout; outside it nothing is touched.

/**
 * @param {boolean} enabled
 * @param {{ captureErrors?: boolean, silenceWarn?: boolean, silenceStdoutWrite?: boolean }} [opts]
 *   captureErrors      keep the last console.error message for lastError()
 *                      instead of dropping it
 *   silenceWarn        also silence console.warn
 *   silenceStdoutWrite also swallow direct process.stdout.write calls (the
 *                      download progress line)
 * @returns {{ enabled: boolean, emit(obj: object): void, lastError(): string|null }}
 */
function createJsonMode(
  enabled,
  { captureErrors = false, silenceWarn = false, silenceStdoutWrite = false } = {},
) {
  // Captured before any override so emit() still reaches the real stdout.
  const realWrite = process.stdout.write.bind(process.stdout);
  let lastError = null;

  if (enabled) {
    console.log = () => {};
    if (silenceWarn) console.warn = () => {};
    console.error = captureErrors
      ? (...args) => {
          lastError = args.map(String).join(" ");
        }
      : () => {};
    if (silenceStdoutWrite) process.stdout.write = () => true;
  }

  return {
    enabled,
    emit(obj) {
      realWrite(JSON.stringify(obj) + "\n");
    },
    lastError: () => lastError,
  };
}

module.exports = { createJsonMode };
