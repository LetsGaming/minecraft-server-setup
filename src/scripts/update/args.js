// scripts/update/args.js
//
// Shared argument parser for all update scripts.
//
// Supports both positional and flag-based args:
//   node script.js positional-value --flag=value --bool-flag
//
// Usage:
//   const { getArg, getFlag, hasFlag, positional } = parseArgs(spec);
//
//   spec: {
//     flags:      { flagName: 'defaultValue' | null },   // --flagName=value
//     boolFlags:  ['flagName'],                           // --flagName  (boolean)
//     positional: ['firstArgName', 'secondArgName'],      // ordered positional names
//   }
//
// Resolution order: --flag=value > positional > default

/**
 * @param {object} spec
 * @param {Record<string, string|null>} [spec.flags]
 * @param {string[]} [spec.boolFlags]
 * @param {string[]} [spec.positional]
 * @returns {{ get(name: string): string|null, bool(name: string): boolean }}
 */
function parseArgs(spec = {}) {
  const raw = process.argv.slice(2);

  const { flags = {}, boolFlags = [], positional: positionalNames = [] } = spec;

  // Parse --key=value and --bool flags
  const parsedFlags = {};
  const parsedBools = {};
  const positionalValues = [];

  for (const arg of raw) {
    if (arg.startsWith("--")) {
      const eqIdx = arg.indexOf("=");
      if (eqIdx !== -1) {
        const key = arg.slice(2, eqIdx);
        parsedFlags[key] = arg.slice(eqIdx + 1);
      } else {
        parsedBools[arg.slice(2)] = true;
      }
    } else {
      positionalValues.push(arg);
    }
  }

  /**
   * Get the value of a named argument.
   * Resolution order: --name=value  >  positional (by index)  >  default from spec
   *
   * @param {string} name
   * @returns {string|null}
   */
  function get(name) {
    if (parsedFlags[name] !== undefined) return parsedFlags[name];

    const posIdx = positionalNames.indexOf(name);
    if (posIdx !== -1 && positionalValues[posIdx] !== undefined) {
      return positionalValues[posIdx];
    }

    if (flags[name] !== undefined) return flags[name];

    return null;
  }

  /**
   * Get the value of a boolean flag.
   * @param {string} name
   * @returns {boolean}
   */
  function bool(name) {
    return parsedBools[name] === true;
  }

  /**
   * All positional values that were not consumed by named positionals.
   * Useful when a script accepts a variable number of positional args.
   */
  const extra = positionalValues.slice(positionalNames.length);

  return { get, bool, extra };
}

module.exports = { parseArgs };
