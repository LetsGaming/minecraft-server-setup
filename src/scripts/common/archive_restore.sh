#!/bin/bash
# Helpers shared by backup/restore.sh and rollback.sh. Source after
# load_variables.sh so BACKUPS_PATH is set. Functions report on stderr and
# return non-zero; they never exit, so callers decide how to unwind.

_ar_error() { echo "[ERROR] $*" >&2; }

# resolve_backup_file <path> <tier_dir>
# Prints the canonical path of a backup archive. <path> is either absolute or
# relative to <tier_dir>. The canonical path must be a regular file inside
# BACKUPS_PATH, so symlinks and ".." cannot reach outside the backups root.
resolve_backup_file() {
  local requested="$1" tier_dir="$2" candidate root resolved

  case "/$requested/" in
    */../*) _ar_error "Backup path must not contain '..': $requested"; return 1 ;;
  esac

  if [[ "$requested" == /* ]]; then
    candidate="$requested"
  else
    candidate="$tier_dir/$requested"
  fi

  root="$(realpath -e -- "$BACKUPS_PATH")" || { _ar_error "Backups directory does not exist: $BACKUPS_PATH"; return 1; }
  resolved="$(realpath -e -- "$candidate" 2>/dev/null)" || { _ar_error "Specified backup does not exist: $requested"; return 1; }

  if [[ "$resolved" != "$root"/* ]]; then
    _ar_error "Backup is outside the backups directory: $requested"
    return 1
  fi
  if [[ ! -f "$resolved" ]]; then
    _ar_error "Specified backup is not a regular file: $requested"
    return 1
  fi

  printf '%s\n' "$resolved"
}

# validate_archive <file>
# Fails unless the whole archive decompresses and lists cleanly, so a corrupt
# or truncated file is caught before anything on disk is touched.
validate_archive() {
  local file="$1"
  case "$file" in
    *.tar.zst)
      zstd -t "$file" >/dev/null 2>&1 || { _ar_error "Archive failed zstd integrity test: $file"; return 1; }
      ( set -o pipefail; zstd -d "$file" -c | tar -tf - >/dev/null ) 2>/dev/null \
        || { _ar_error "Archive contents cannot be listed: $file"; return 1; }
      ;;
    *.tar.gz)
      ( set -o pipefail; tar -tzf "$file" >/dev/null ) 2>/dev/null \
        || { _ar_error "Archive contents cannot be listed: $file"; return 1; }
      ;;
    *)
      _ar_error "Unsupported backup file format: $file"
      return 1
      ;;
  esac
}

# extract_archive <file> <dest_dir>
# Extracts into a fresh directory. On failure the partial directory is removed.
extract_archive() {
  local file="$1" dest="$2"
  rm -rf -- "$dest"
  mkdir -p -- "$dest" || return 1
  case "$file" in
    *.tar.zst) ( set -o pipefail; zstd -d "$file" -c | tar -xf - -C "$dest" ) ;;
    *.tar.gz)  tar -xzf "$file" -C "$dest" ;;
    *)         _ar_error "Unsupported backup file format: $file"; false ;;
  esac || {
    _ar_error "Extraction failed: $file"
    rm -rf -- "$dest"
    return 1
  }
}

# swap_server_dir <staging_dir> <server_dir>
# Replaces <server_dir> with <staging_dir> by renaming, so the server directory
# is either the old contents or the new ones, never a half-written mix. If the
# second rename fails the original is moved back. Both paths must live on the
# same filesystem (the staging directory is created next to the server dir).
swap_server_dir() {
  local staging="$1" server="${2%/}" old
  old="$server.pre-restore.$$"

  if [[ -e "$server" ]]; then
    chmod --reference="$server" -- "$staging" 2>/dev/null || true
    mv -- "$server" "$old" || { _ar_error "Could not move the current server directory aside"; return 1; }
  fi
  if ! mv -- "$staging" "$server"; then
    _ar_error "Could not move the restored files into place"
    if [[ -e "$old" ]]; then
      mv -- "$old" "$server" || _ar_error "Original server data is preserved at: $old"
    fi
    return 1
  fi
  rm -rf -- "$old"
}

# server_is_running
# Live check, never cached. Returns 0 when the server is up, 1 when every
# available signal says it is down, 2 when no signal could be consulted. Needs
# server_control.sh (for _use_rcon, _rcon_send and session_running).
server_is_running() {
  local can_check=false state

  if _use_rcon; then
    can_check=true
    _rcon_send "list" &>/dev/null && return 0
  fi
  if command -v screen &>/dev/null; then
    can_check=true
    session_running && return 0
  fi
  if command -v systemctl &>/dev/null; then
    can_check=true
    state="$(systemctl is-active "${INSTANCE_NAME}.service" 2>/dev/null || true)"
    case "$state" in
      active|activating|deactivating|reloading) return 0 ;;
    esac
  fi

  $can_check || return 2
  return 1
}

# require_server_stopped
# Fails (after saying why) unless the server is positively known to be down.
require_server_stopped() {
  local rc=0
  server_is_running || rc=$?
  case "$rc" in
    0) _ar_error "$INSTANCE_NAME is running. Stop the server before restoring."; return 1 ;;
    2) _ar_error "Cannot tell whether $INSTANCE_NAME is running (no RCON, screen or systemctl); refusing to continue."; return 1 ;;
  esac
}
