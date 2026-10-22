#!/bin/bash
# Shared by the backup, cleanup and supervisor scripts: logging, exit codes,
# configuration defaults and validation, and the CPU/IO priority wrapper.
# Source after load_variables.sh. Functions return non-zero and log instead of
# exiting, except bk_die.

if [[ -n "${_BK_COMMON_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_BK_COMMON_LOADED=1

BK_COMPONENT="${BK_COMPONENT:-backup}"
BK_STAGE="${BK_STAGE:-start}"
BK_FAIL_REASON=""

# Exit codes beyond 0/1 that callers (run_backup.sh, the API wrapper) can map.
BK_EX_CONTENT=65    # archive verified but holds no world
BK_EX_NOSPACE=73    # not enough free space, even after eviction
BK_EX_SKIP=75       # lock held, nothing done

bk_log() {
  local level="$1"
  shift
  local line
  line="$(date +'%F %T') [$level] [$BK_COMPONENT] $*"
  echo "$line"
  if [[ "${BK_LOG_STDERR:-}" == 1 && ( "$level" == WARN || "$level" == ERROR ) ]]; then
    echo "$line" >&2
  fi
}

bk_set_stage() { BK_STAGE="$1"; }

bk_die() {
  local code="$1"
  shift
  BK_FAIL_REASON="$*"
  bk_log ERROR "$*"
  exit "$code"
}

# ── configuration ──

_bk_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# _bk_default_int <var> <default> <min> [max]: keeps a valid value, replaces an
# invalid one with the default and says so.
_bk_default_int() {
  local var="$1" def="$2" min="$3" max="${4:-}" val="${!1:-}"
  if [[ -z "$val" ]]; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  if ! _bk_is_int "$val" || (( val < min )) || { [[ -n "$max" ]] && (( val > max )); }; then
    bk_log WARN "$var='$val' is not valid; using $def"
    printf -v "$var" '%s' "$def"
  fi
}

_bk_default_bool() {
  local var="$1" def="$2" val="${!1:-}"
  case "$val" in
    true|false) ;;
    "") printf -v "$var" '%s' "$def" ;;
    *) bk_log WARN "$var='$val' is not true or false; using $def"; printf -v "$var" '%s' "$def" ;;
  esac
}

_bk_default_threads() {
  local cores half
  cores="$(nproc 2>/dev/null || echo 2)"
  _bk_is_int "$cores" || cores=2
  half=$(( cores / 2 ))
  (( half < 1 )) && half=1
  (( half > 4 )) && half=4
  echo "$half"
}

# bk_load_config: defaults and validation for every key the backup scripts
# read. Returns 1 only for a required key that cannot be defaulted.
bk_load_config() {
  if ! _bk_is_int "${COMPRESSION_LEVEL:-}" || (( COMPRESSION_LEVEL < 1 || COMPRESSION_LEVEL > 19 )); then
    bk_log ERROR "COMPRESSION_LEVEL='${COMPRESSION_LEVEL:-}' must be a whole number between 1 and 19"
    return 1
  fi
  if [[ -n "${MAX_STORAGE_GB:-}" ]] && { ! _bk_is_int "$MAX_STORAGE_GB" || (( MAX_STORAGE_GB < 1 )); }; then
    bk_log WARN "MAX_STORAGE_GB='$MAX_STORAGE_GB' is not a whole number of GB; the storage limit is not enforced"
    MAX_STORAGE_GB=""
  fi
  _bk_default_int MAX_HOURLY_BACKUPS 3 0
  _bk_default_int MAX_DAILY_BACKUPS 3 0
  _bk_default_int MAX_WEEKLY_BACKUPS 2 0
  _bk_default_int MAX_MONTHLY_BACKUPS 1 0
  _bk_default_int MAX_UPDATE_BACKUPS 5 0
  _bk_default_int MAX_CUSTOM_BACKUPS 0 0
  _bk_default_int SAVE_TIMEOUT_SECONDS 120 1

  local archive_default=$(( COMPRESSION_LEVEL > 15 ? COMPRESSION_LEVEL : 15 ))
  _bk_default_int BACKUP_HOURLY_LEVEL "$COMPRESSION_LEVEL" 1 19
  _bk_default_int BACKUP_ARCHIVE_LEVEL "$archive_default" 1 19
  _bk_default_int BACKUP_ZSTD_THREADS "$(_bk_default_threads)" 0 256
  case "${BACKUP_STAGING_MODE:-}" in
    auto|mirror|reflink|fresh) ;;
    "") BACKUP_STAGING_MODE=auto ;;
    *) bk_log WARN "BACKUP_STAGING_MODE='$BACKUP_STAGING_MODE' is unknown; using auto"; BACKUP_STAGING_MODE=auto ;;
  esac
  _bk_default_bool BACKUP_FOLLOW_SYMLINKS true
  BACKUP_EXTRA_EXCLUDES="${BACKUP_EXTRA_EXCLUDES:-}"
  _bk_default_int BACKUP_SPACE_MARGIN_PCT 5 0 50
  _bk_default_int BACKUP_TIMEOUT_MINUTES 120 1
  _bk_default_int BACKUP_SKIP_ALERT_AFTER 3 1
  _bk_default_int BACKUP_ARCHIVE_MAX_ATTEMPTS 3 1
  _bk_default_int BACKUP_LOG_MAX_MB 10 1
  _bk_default_bool RESTORE_KEEP_OLD true
  _bk_default_int RESTORE_KEEP_OLD_DAYS 7 0
  RESTORE_CARRY_OVER="${RESTORE_CARRY_OVER-logs crash-reports ledger.sqlite}"
  export MAX_HOURLY_BACKUPS MAX_DAILY_BACKUPS MAX_WEEKLY_BACKUPS MAX_MONTHLY_BACKUPS MAX_UPDATE_BACKUPS MAX_CUSTOM_BACKUPS
  export BACKUP_HOURLY_LEVEL BACKUP_ARCHIVE_LEVEL BACKUP_ZSTD_THREADS BACKUP_STAGING_MODE BACKUP_FOLLOW_SYMLINKS
  export BACKUP_EXTRA_EXCLUDES BACKUP_SPACE_MARGIN_PCT BACKUP_TIMEOUT_MINUTES BACKUP_SKIP_ALERT_AFTER
  export BACKUP_ARCHIVE_MAX_ATTEMPTS BACKUP_LOG_MAX_MB RESTORE_KEEP_OLD RESTORE_KEEP_OLD_DAYS RESTORE_CARRY_OVER
  return 0
}

bk_zstd_threads() { echo "${BACKUP_ZSTD_THREADS:-$(_bk_default_threads)}"; }

# ── priority ──

# ionice only has an effect under the BFQ scheduler; on mq-deadline or none
# (NVMe, virtio) the real levers are fewer zstd threads, a lower level and less
# data copied. The probe runs each part once: util-linux ionice exits non-zero
# without running the command when ioprio_set is refused unless -t is given,
# and "command -v ionice" proves nothing about that.
BK_NICE=()
_BK_NICE_PROBED=false

bk_probe_priority() {
  $_BK_NICE_PROBED && return 0
  _BK_NICE_PROBED=true
  BK_NICE=()
  if command -v ionice &>/dev/null && ionice -c2 -n7 -t true &>/dev/null; then
    BK_NICE+=(ionice -c2 -n7 -t)
  fi
  if command -v nice &>/dev/null && nice -n 10 true &>/dev/null; then
    BK_NICE+=(nice -n 10)
  fi
  return 0
}

bk_nice() {
  bk_probe_priority
  "${BK_NICE[@]}" "$@"
}

# bk_private_dir <dir>
# Makes <dir> writable by this user alone and fails when that cannot be
# verified. Setup grants the API wrapper's service user a default ACL on the
# backups folder (so it can delete archives); a staging or sidecar directory
# that inherited it would let that user plant content in the next archive or
# vouch for a corrupt one, past the S-004 trust boundary.
bk_private_dir() {
  local dir="$1" info owner mode
  mkdir -p -- "$dir" || return 1
  chmod 700 -- "$dir" 2>/dev/null || true
  if [[ "$(uname -s 2>/dev/null)" == Linux ]] && command -v setfacl >/dev/null 2>&1; then
    setfacl -b -k -- "$dir" 2>/dev/null || true
  fi
  info="$(stat -c '%u %a' -- "$dir" 2>/dev/null)" || return 1
  owner="${info%% *}"
  mode="${info##* }"
  [[ "$owner" == "$(id -u)" ]] || { bk_log WARN "$dir is owned by uid $owner, not by $(id -un)"; return 1; }
  # Group and other must have no write bit; the owner digit is left alone so
  # hosts that cannot represent 700 (Windows) still pass.
  if [[ ! "$mode" =~ ^[0-7]?[0-7]?[0-7]?[0-7][0-7][0-7]$ ]] || (( (10#${mode: -2:1} & 2) != 0 || (10#${mode: -1:1} & 2) != 0 )); then
    bk_log WARN "$dir has mode $mode and is writable by others"
    return 1
  fi
  if [[ "$(uname -s 2>/dev/null)" == Linux ]] && command -v getfacl >/dev/null 2>&1; then
    if getfacl -cp -- "$dir" 2>/dev/null | grep -Eq '^(user|group):[^:]+:|^default:'; then
      bk_log WARN "$dir carries ACL entries for other users that could not be removed"
      return 1
    fi
  fi
  return 0
}

# bk_human_bytes <bytes>: 2.1 GiB style figure for log lines.
bk_human_bytes() {
  local b="${1:-0}"
  _bk_is_int "$b" || { echo "$b"; return; }
  if (( b >= 1073741824 )); then
    awk -v b="$b" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'
  elif (( b >= 1048576 )); then
    awk -v b="$b" 'BEGIN { printf "%.1f MiB", b / 1048576 }'
  elif (( b >= 1024 )); then
    awk -v b="$b" 'BEGIN { printf "%.1f KiB", b / 1024 }'
  else
    echo "$b B"
  fi
}

bk_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local t="${EPOCHREALTIME//[.,]/}"
    echo $(( 10#${t} / 1000 ))
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# bk_ms_to_s <ms>: seconds with one decimal.
bk_ms_to_s() { awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 1000 }'; }

bk_file_size() { stat -c %s -- "$1" 2>/dev/null || echo 0; }
bk_link_count() { stat -c %h -- "$1" 2>/dev/null || echo 1; }
