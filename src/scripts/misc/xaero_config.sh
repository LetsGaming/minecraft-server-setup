#!/bin/bash
# Keeps the Xaero mods client-optional: patches the three config keys that stop
# the server from registering status effects (vanilla clients can then join) and
# make everyone's position visible to everyone. Usage:
#   bash xaero_config.sh apply <server_dir>   write the keys (idempotent)
#   bash xaero_config.sh check <server_dir>   one line per key: OK, DRIFT, MISSING or SKIP
# check exits 1 when any key is DRIFT or MISSING. Nothing is created when the
# server has no Xaero jar in mods/. All other lines of a config file, its line
# endings and its mode stay as they are.

set -u

# path (under the server dir) | key | value | jar prefixes that make the key apply
KEYS=(
  "config/xaero/lib/common.cfg|everyone_tracks_everyone|true|xaerominimap xaeroworldmap"
  "config/xaero/minimap/common.cfg|register_minimap_status_effects|false|xaerominimap"
  "config/xaero/world-map/common.cfg|register_status_effects|false|xaeroworldmap"
)

has_jar() { # server_dir prefix
  local f
  shopt -s nullglob nocaseglob
  for f in "$1/mods/$2"*.jar; do
    if [[ -f "$f" ]]; then shopt -u nullglob nocaseglob; return 0; fi
  done
  shopt -u nullglob nocaseglob
  return 1
}

applies() { # server_dir prefixes
  local p
  for p in $2; do has_jar "$1" "$p" && return 0; done
  return 1
}

# Splits a key line into prefix (through the equals sign and blanks), the value
# token and whatever follows it (blanks, a comment, a carriage return).
line_re() { printf '^([[:space:]]*%s[[:space:]]*=[[:space:]]*)([^[:space:]#]*)(.*)$' "$1"; }

# Prints the value of the first line holding the key.
read_value() { # file key
  local line re
  re="$(line_re "$2")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[2]}"
      return 0
    fi
  done < "$1"
  return 1
}

# Rewrites the file into $4 with the first line of the key set to the value.
# Returns non-zero when any write fails.
render() { # file key value out
  local file="$1" key="$2" value="$3" out="$4"
  local line re eol=$'\n' found=false last_nl=true crlf=false
  re="$(line_re "$key")"
  : > "$out" || return 1
  while IFS= read -r line || { [[ -n "$line" ]] && last_nl=false; }; do
    [[ "$line" == *$'\r' ]] && crlf=true
    if ! $found && [[ "$line" =~ $re ]]; then
      found=true
      line="${BASH_REMATCH[1]}${value}${BASH_REMATCH[3]}"
    fi
    printf '%s' "$line" >> "$out" || return 1
    if $last_nl; then printf '\n' >> "$out" || return 1; fi
  done < "$file"
  if ! $found; then
    $crlf && eol=$'\r\n'
    if ! $last_nl; then printf '%s' "$eol" >> "$out" || return 1; fi
    printf '%s = %s%s' "$key" "$value" "$eol" >> "$out" || return 1
  fi
  return 0
}

CURRENT_TMP=""
cleanup_tmp() { [[ -n "$CURRENT_TMP" ]] && rm -f "$CURRENT_TMP"; return 0; }

apply_key() { # file key value
  local file="$1" key="$2" value="$3" dir
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  CURRENT_TMP="$(mktemp "$dir/.xaero_config.XXXXXX")" || { CURRENT_TMP=""; return 1; }
  if [[ ! -f "$file" ]]; then
    chmod "$(printf '%o' $((0666 & ~$(umask))))" "$CURRENT_TMP" 2> /dev/null
    printf '%s = %s\n' "$key" "$value" > "$CURRENT_TMP" || { cleanup_tmp; CURRENT_TMP=""; return 1; }
  else
    # cp -p carries the mode over; the redirects in render keep it.
    if ! cp -p "$file" "$CURRENT_TMP" || ! render "$file" "$key" "$value" "$CURRENT_TMP"; then
      cleanup_tmp; CURRENT_TMP=""
      return 1
    fi
    if cmp -s "$file" "$CURRENT_TMP"; then
      cleanup_tmp; CURRENT_TMP=""
      return 0
    fi
  fi
  mv -f "$CURRENT_TMP" "$file" || { cleanup_tmp; CURRENT_TMP=""; return 1; }
  CURRENT_TMP=""
}

cmd_apply() {
  local dir="$1" entry rel key value jars rc=0
  for entry in "${KEYS[@]}"; do
    IFS='|' read -r rel key value jars <<< "$entry"
    applies "$dir" "$jars" || continue
    if ! apply_key "$dir/$rel" "$key" "$value"; then
      echo "Could not patch $rel ($key)" >&2
      rc=1
    fi
  done
  return $rc
}

cmd_check() {
  local dir="$1" entry rel key value jars found rc=0
  for entry in "${KEYS[@]}"; do
    IFS='|' read -r rel key value jars <<< "$entry"
    if ! applies "$dir" "$jars"; then
      echo "SKIP $rel"
    elif [[ ! -f "$dir/$rel" ]] || ! found="$(read_value "$dir/$rel" "$key")"; then
      echo "MISSING $rel $key"
      rc=1
    elif [[ "$found" == "$value" ]]; then
      echo "OK $rel $key"
    else
      echo "DRIFT $rel $key (found $found, want $value)"
      rc=1
    fi
  done
  return $rc
}

main() {
  trap cleanup_tmp EXIT
  trap 'cleanup_tmp; exit 130' INT
  trap 'cleanup_tmp; exit 143' TERM
  if [[ $# -ne 2 || ! -d "$2" ]]; then
    echo "Usage: xaero_config.sh apply|check <server_dir>" >&2
    return 2
  fi
  case "$1" in
    apply) cmd_apply "$2" ;;
    check) cmd_check "$2" ;;
    *) echo "Usage: xaero_config.sh apply|check <server_dir>" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
