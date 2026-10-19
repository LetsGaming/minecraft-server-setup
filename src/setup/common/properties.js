"use strict";

/**
 * Text helpers for Java .properties files (server.properties).
 */

/**
 * A value as it must appear on one .properties line. Newlines are dropped.
 * Leading whitespace is protected because the loader skips it, and an odd run
 * of trailing backslashes is closed because it would continue the line onto
 * the next property. Backslash sequences the caller wrote on purpose (\n and
 * § in a MOTD) are passed through as written.
 */
function escapePropertyValue(value) {
  let v = String(value).replace(/\r\n|\r|\n/g, "");
  v = v.replace(/^[ \t\f]+/, (ws) => ws.replace(/ /g, "\\ ").replace(/\t/g, "\\t").replace(/\f/g, "\\f"));
  const trailing = /\\+$/.exec(v);
  if (trailing && trailing[0].length % 2 === 1) v += "\\";
  return v;
}

/** Set each key in `content` (replacing its line, or appending one) and return the new text. */
function applyProperties(content, updates) {
  let text = content;
  for (const [key, value] of Object.entries(updates)) {
    const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const regex = new RegExp(`^${escapedKey}=.*$`, "m");
    const line = `${key}=${escapePropertyValue(value)}`;
    // A function replacer: a string one would read $&, $1 and $$ in the value.
    if (regex.test(text)) text = text.replace(regex, () => line);
    else text += `\n${line}`;
  }
  return text;
}

module.exports = { escapePropertyValue, applyProperties };
