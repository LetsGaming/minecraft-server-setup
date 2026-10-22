#!/bin/bash
# Free-space estimate and preflight. Needs bk_common.sh, bk_state.sh,
# SERVER_PATH and BACKUPS_PATH.

if [[ -n "${_BK_SPACE_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_BK_SPACE_LOADED=1

# bk_space_available <dir>: free bytes on the filesystem holding <dir>.
bk_space_available() {
  local dir="$1" avail
  [[ -d "$dir" ]] || dir="$(dirname "$dir")"
  avail="$(df --output=avail -B1 -- "$dir" 2>/dev/null | tail -n1 | tr -d ' ')"
  if ! [[ "$avail" =~ ^[0-9]+$ ]]; then
    avail="$(df -Pk -- "$dir" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }')"
  fi
  [[ "$avail" =~ ^[0-9]+$ ]] || return 1
  echo "$avail"
}

bk_space_server_bytes() {
  local b
  b="$(du -sb -- "$SERVER_PATH" 2>/dev/null | cut -f1)"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  echo "$b"
}

# bk_space_estimate_archive: the last archive's size plus 20 percent, else half
# the server size.
bk_space_estimate_archive() {
  local last
  last="$(bk_state_last_field bytes 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( last > 0 )); then
    echo $(( last * 12 / 10 ))
  else
    echo $(( $(bk_space_server_bytes) / 2 ))
  fi
}

# bk_space_needed <mode>: bytes a run of that staging mode may write.
bk_space_needed() {
  local mode="$1" archive
  archive="$(bk_space_estimate_archive)"
  case "$mode" in
    fresh) echo $(( archive + $(bk_space_server_bytes) )) ;;
    mirror)
      if [[ -d "$BACKUPS_PATH/.stage/mirror" ]]; then echo "$archive"
      else echo $(( archive + $(bk_space_server_bytes) )); fi ;;
    *) echo "$archive" ;;
  esac
}

# bk_space_preflight <mode> <cleanup_script>
# 0 when the run fits; otherwise asks cleanup to make room, re-checks, and
# returns 73 with BK_FAIL_REASON set when it still does not fit.
bk_space_preflight() {
  local mode="$1" cleanup="$2" need avail margin usable short
  need="$(bk_space_needed "$mode")"
  avail="$(bk_space_available "$BACKUPS_PATH")" || { bk_log WARN "Cannot measure free space; skipping the preflight"; return 0; }
  margin=$(( avail * ${BACKUP_SPACE_MARGIN_PCT:-5} / 100 ))
  usable=$(( avail - margin ))
  if (( usable >= need )); then
    bk_log INFO "Space preflight: need about $(bk_human_bytes "$need"), $(bk_human_bytes "$avail") free"
    return 0
  fi
  short=$(( need - usable ))
  bk_log WARN "Space preflight: need about $(bk_human_bytes "$need") but only $(bk_human_bytes "$usable") usable; asking cleanup to free $(bk_human_bytes "$short")"
  if [[ -f "$cleanup" ]]; then
    bash "$cleanup" --make-room "$short" || true
  fi
  avail="$(bk_space_available "$BACKUPS_PATH")" || return 0
  margin=$(( avail * ${BACKUP_SPACE_MARGIN_PCT:-5} / 100 ))
  usable=$(( avail - margin ))
  if (( usable >= need )); then
    bk_log INFO "Space preflight: $(bk_human_bytes "$avail") free after eviction"
    return 0
  fi
  BK_FAIL_REASON="not enough free space: need about $(bk_human_bytes "$need"), $(bk_human_bytes "$usable") usable after eviction"
  bk_log ERROR "$BK_FAIL_REASON"
  return "$BK_EX_NOSPACE"
}
