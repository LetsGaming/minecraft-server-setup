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
