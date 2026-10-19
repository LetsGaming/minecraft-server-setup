#!/bin/bash
# Merging new keys of a source JSON config into a deployed one.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.

_count_new_json_keys() {
  local existing="$1" new_file="$2"
  node -e "
    const fs = require('fs');
    const ex = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const nw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    let n = 0;
    function count(t, s) {
      for (const k of Object.keys(s)) {
        if (!(k in t)) { n++; }
        else if (s[k] && typeof s[k] === 'object' && !Array.isArray(s[k]) &&
                 t[k] && typeof t[k] === 'object' && !Array.isArray(t[k])) {
          count(t[k], s[k]);
        }
      }
    }
    count(ex, nw);
    console.log(n);
  " "$existing" "$new_file" 2>/dev/null || echo "0"
}

_merge_json_config() {
  local existing="$1" new_file="$2"
  node -e "
    const fs = require('fs');
    const ex = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const nw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    function merge(target, source) {
      for (const [k, v] of Object.entries(source)) {
        if (!(k in target)) {
          target[k] = v;
        } else if (v && typeof v === 'object' && !Array.isArray(v) &&
                   target[k] && typeof target[k] === 'object' && !Array.isArray(target[k])) {
          merge(target[k], v);
        }
      }
    }
    merge(ex, nw);
    fs.writeFileSync(process.argv[2], JSON.stringify(ex, null, 2) + '\n');
  " "$existing" "$new_file"
}
