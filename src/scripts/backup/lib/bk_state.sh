#!/bin/bash
# Per-instance backup state under $BACKUPS_PATH: the status of the last run
# (.meta/last_backup.json), day flags, attempt counters and the skip streak
# (.backup_flags/). Needs bk_common.sh.

if [[ -n "${_BK_STATE_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_BK_STATE_LOADED=1

bk_state_flags_dir() { echo "$BACKUPS_PATH/.backup_flags"; }
bk_state_meta_dir() { echo "$BACKUPS_PATH/.meta"; }
bk_state_last_file() { echo "$BACKUPS_PATH/.meta/last_backup.json"; }

_bk_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

_bk_json_list() {
  local out="" item
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    [[ -n "$out" ]] && out+=","
    out+="$(_bk_json_str "$item")"
  done
  printf '[%s]' "$out"
}

# bk_state_write_last <rc> <tier> <file> <bytes> <seconds> <stage>
# Extra fields come from BK_TIERS (space separated), BK_SAVE_OFF_SECONDS,
# BK_STAGING, BK_LEVEL and BK_THREADS when set. Written atomically.
bk_state_write_last() {
  local rc="$1" tier="$2" file="$3" bytes="${4:-0}" seconds="${5:-0}" stage="$6"
  local dir tmp finished tiers
  dir="$(bk_state_meta_dir)"
  mkdir -p "$dir" || return 1
  finished="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  # shellcheck disable=SC2086
  tiers="$(_bk_json_list ${BK_TIERS:-$tier})"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
  tmp="$dir/.last_backup.json.$$"
  printf '{"finished":%s,"rc":%s,"tier":%s,"tiers":%s,"file":%s,"bytes":%s,"seconds":%s,"save_off_seconds":%s,"staging":%s,"level":%s,"threads":%s,"stage":%s}\n' \
    "$(_bk_json_str "$finished")" "$rc" "$(_bk_json_str "$tier")" "$tiers" "$(_bk_json_str "$file")" \
    "$bytes" "$seconds" "${BK_SAVE_OFF_SECONDS:-0}" "$(_bk_json_str "${BK_STAGING:-}")" \
    "${BK_LEVEL:-0}" "${BK_THREADS:-0}" "$(_bk_json_str "$stage")" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$(bk_state_last_file)"
}

# bk_state_last_field <name>: prints one scalar field of last_backup.json.
bk_state_last_field() {
  local f
  f="$(bk_state_last_file)"
  [[ -f "$f" ]] || return 1
  sed -n "s/.*\"$1\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}[,}].*/\1/p" "$f" | head -n1
}

# bk_state_skip_streak inc|reset|get: prints the count after the change.
bk_state_skip_streak() {
  local dir f n=0
  dir="$(bk_state_flags_dir)"
  mkdir -p "$dir"
  f="$dir/skip_streak"
  [[ -f "$f" ]] && n="$(cat "$f" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  case "$1" in
    inc) n=$((n + 1)); echo "$n" > "$f" ;;
    reset) n=0; rm -f -- "$f" ;;
  esac
  echo "$n"
}

# bk_state_attempts <tier> <date> inc|get: failed attempts of that tier today.
bk_state_attempts() {
  local tier="$1" date="$2" op="$3" dir f n=0
  dir="$(bk_state_flags_dir)"
  mkdir -p "$dir"
  f="$dir/attempts_${tier}_${date}"
  [[ -f "$f" ]] && n="$(cat "$f" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if [[ "$op" == inc ]]; then
    n=$((n + 1))
    echo "$n" > "$f"
  fi
  echo "$n"
}

bk_state_flag_exists() { [[ -e "$(bk_state_flags_dir)/$1" ]]; }
bk_state_flag_touch() { mkdir -p "$(bk_state_flags_dir)" && touch "$(bk_state_flags_dir)/$1"; }
