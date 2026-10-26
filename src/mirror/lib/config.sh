#!/bin/bash
# The mirror's settings in an instance's deployed common/variables.txt. Sourced by
# mirror.sh. Everything the mirror writes sits between two marker lines, so a
# later setup run replaces exactly that block and never touches the suite's own
# values (migrate.sh keeps variables.txt values and only appends new ones).

MIRROR_BLOCK_BEGIN="# >>> mirror (managed by mirror.sh; edit with mirror.sh, not by hand) >>>"
MIRROR_BLOCK_END="# <<< mirror <<<"

# mirror_dquote <value>: the value as a double-quoted shell word.
mirror_dquote() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\$/\\\$}"
  v="${v//\`/\\\`}"
  printf '"%s"' "$v"
}

# mirror_config_strip <file>: the file without the managed block, on stdout.
mirror_config_strip() {
  awk -v b="$MIRROR_BLOCK_BEGIN" -v e="$MIRROR_BLOCK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$1"
}

# mirror_config_write <file> KEY=VALUE...: replaces the managed block with these
# keys (no block at all when none are given). The file keeps its mode and owner.
mirror_config_write() {
  local file="$1" tmp pair
  shift
  [[ -f "$file" ]] || { echo "variables.txt not found: $file" >&2; return 1; }
  tmp="$(mktemp "$file.mirror.XXXXXX")" || return 1
  chmod --reference="$file" "$tmp" 2> /dev/null || chmod 600 "$tmp"
  {
    mirror_config_strip "$file"
    if (($# > 0)); then
      echo "$MIRROR_BLOCK_BEGIN"
      for pair in "$@"; do
        [[ "$pair" =~ ^MIRROR_[A-Z0-9_]+= ]] || { echo "not a MIRROR_ setting: $pair" >&2; rm -f "$tmp"; return 1; }
        printf '%s=%s\n' "${pair%%=*}" "$(mirror_dquote "${pair#*=}")"
      done
      echo "$MIRROR_BLOCK_END"
    fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

# mirror_config_has <file>: true when the file has a managed block.
mirror_config_has() { grep -qxF -- "$MIRROR_BLOCK_BEGIN" "$1" 2> /dev/null; }

# mirror_config_value <file> KEY: the value of KEY in the file, as the shell
# would read it ("" when unset). Evaluated in a subshell so nothing leaks.
mirror_config_value() {
  ( set +u; source "$1" > /dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}
