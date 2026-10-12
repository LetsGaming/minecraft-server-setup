#!/usr/bin/env bash
set -e

# Ensure script is sourced from other scripts
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file is meant to be sourced, not executed directly."
    exit 1
fi

_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Per-instance script lock ──

_have_flock() { command -v flock > /dev/null 2>&1; }

# acquire_instance_lock <name>
# Takes an exclusive lock for <name> on this instance and keeps it until the
# process exits. Returns 1 when another run already holds it.
#
# The lock lives in a private directory (INSTANCE_LOCK_DIR, else the runtime
# dir, else scripts/.locks), never directly in the world-writable /tmp where
# another local user could squat the path. With flock the lock dies with the
# process, so no cleanup trap is needed and an overridden EXIT trap cannot
# strand it. Without flock a mkdir lock is used; such a lock is only released
# by release_instance_lock, so a script that installs its own EXIT trap must
# call that from it.
_INSTANCE_LOCK_DIR_HELD=""

acquire_instance_lock() {
  local name="$1"
  local dir="${INSTANCE_LOCK_DIR:-}"
  if [[ -z "$dir" ]]; then
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
      dir="$XDG_RUNTIME_DIR/minecraft"
    else
      dir="$_UTILS_DIR/../.locks"
    fi
  fi
  mkdir -p "$dir"
  chmod 700 "$dir" 2> /dev/null || true

  local lock="$dir/${name}_${INSTANCE_NAME:-default}.lock"

  if _have_flock; then
    exec 8> "$lock"
    if ! flock -n 8; then
      echo "$name is already running for ${INSTANCE_NAME:-this instance} (lock $lock). Exiting."
      return 1
    fi
    return 0
  fi

  local held="$lock.d"
  if ! mkdir "$held" 2> /dev/null; then
    local other
    other="$(cat "$held/pid" 2> /dev/null || true)"
    if [[ -n "$other" ]] && kill -0 "$other" 2> /dev/null; then
      echo "$name is already running for ${INSTANCE_NAME:-this instance} (pid $other). Exiting."
      return 1
    fi
    rm -rf "$held"
    mkdir "$held" 2> /dev/null || return 1
  fi
  echo "$$" > "$held/pid"
  _INSTANCE_LOCK_DIR_HELD="$held"
  trap release_instance_lock EXIT
  return 0
}

# acquire_operation_lock <kind>
# The one slot for work that rewrites the server and must not overlap with
# itself or with other such work: restore, rollback, and the version upgrade.
# It is separate from the named locks above (own file, own descriptor), so
# holding it never disturbs them. Whoever holds it exports
# MC_OPERATION_LOCK_HELD=1, so the scripts it starts (backup, rollback) pass
# instead of waiting on their parent. Returns 1 when another operation runs.
acquire_operation_lock() {
  local kind="${1:-operation}"
  [[ "${MC_OPERATION_LOCK_HELD:-}" == "1" ]] && return 0

  local dir="${INSTANCE_LOCK_DIR:-}"
  if [[ -z "$dir" ]]; then
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
      dir="$XDG_RUNTIME_DIR/minecraft"
    else
      dir="$_UTILS_DIR/../.locks"
    fi
  fi
  mkdir -p "$dir"
  chmod 700 "$dir" 2> /dev/null || true

  local lock="$dir/operation_${INSTANCE_NAME:-default}.lock"

  if _have_flock; then
    exec 7> "$lock"
    if ! flock -n 7; then
      echo "Another operation ($(cat "$lock.kind" 2> /dev/null || echo unknown)) is running for ${INSTANCE_NAME:-this instance}. Exiting."
      return 1
    fi
  else
    local held="$lock.d"
    if ! mkdir "$held" 2> /dev/null; then
      local other
      other="$(cat "$held/pid" 2> /dev/null || true)"
      if [[ -n "$other" ]] && kill -0 "$other" 2> /dev/null; then
        echo "Another operation ($(cat "$lock.kind" 2> /dev/null || echo unknown)) is running for ${INSTANCE_NAME:-this instance}. Exiting."
        return 1
      fi
      rm -rf "$held"
      mkdir "$held" 2> /dev/null || return 1
    fi
    echo "$$" > "$held/pid"
    _OPERATION_LOCK_DIR_HELD="$held"
    # A script that already has an EXIT trap must call release_operation_lock from it.
    [[ -z "$(trap -p EXIT)" ]] && trap release_operation_lock EXIT
  fi
  echo "$kind" > "$lock.kind" 2> /dev/null || true
  export MC_OPERATION_LOCK_HELD=1
  return 0
}

_OPERATION_LOCK_DIR_HELD=""

release_operation_lock() {
  if [[ -n "$_OPERATION_LOCK_DIR_HELD" ]]; then
    rm -rf "$_OPERATION_LOCK_DIR_HELD"
    _OPERATION_LOCK_DIR_HELD=""
  fi
}

release_instance_lock() {
  if [[ -n "$_INSTANCE_LOCK_DIR_HELD" ]]; then
    rm -rf "$_INSTANCE_LOCK_DIR_HELD"
    _INSTANCE_LOCK_DIR_HELD=""
  fi
}

# Logging setup
log_file_path=""

init_log_file() {
    local log_dir="$1"
    local log_file="$2"

    mkdir -p "$log_dir"
    log_file_path="$log_dir/$log_file"
}

log() {
    local level="$1"
    shift
    local msg
    msg="$(date +'%F %T') [$level] $*"
    echo "$msg"
    echo "$msg" >> "$log_file_path"
}

log_raw() {
    echo "$@" >> "$log_file_path"
}

# Monitors log for player joins and invokes a callback with the player name
on_player_join() {
    local log_path="$1"
    local callback="$2"

    if [[ ! -f "$log_path" ]]; then
        log "ERROR" "Log file not found: $log_path"
        return 1
    fi

    tail -n0 -F "$log_path" 2>/dev/null | while read -r line; do
        if [[ "$line" =~ \]:\ ([a-zA-Z0-9_]+)\ joined\ the\ game ]]; then
            local player="${BASH_REMATCH[1]}"
            "$callback" "$player"
        fi
    done
}
