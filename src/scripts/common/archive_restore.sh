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

# archive_is_trusted <file>
# S-004: the wrapper's service user may write into the backups folders (to
# delete archives), so an archive it planted there must never be restored: the
# restore would run its start.sh and scripts as the server's owner. Only an
# archive owned by the user running the restore, or by root, is accepted.
archive_is_trusted() {
  local file="$1" owner
  owner="$(stat -c %u -- "$file" 2>/dev/null)" || { _ar_error "Cannot read the owner of $file"; return 1; }
  if [[ "$owner" != "$(id -u)" && "$owner" != 0 ]]; then
    _ar_error "Refusing $file: it is owned by uid $owner, not by $(id -un). Only archives this user made are restored."
    return 1
  fi
}

# complete_staged_jars <staging_dir> <server_dir>
# Makes the jars of a restored tree usable before it is swapped in.
#  - S-003: hourly archives leave every *.jar out (server jar, mods,
#    libraries). When the archive holds no jar at all, the current server's
#    jars are carried over at their own paths, so the restored world starts on
#    the same server and mods it ran with.
#  - S-002: archives made before backup.sh kept real jars replaced jars with
#    links into the backups' jars/ folder, which dangle once restored. Each
#    such link is replaced by the real file: the current server's copy at the
#    same path, else the stored copy in jars/.
complete_staged_jars() {
  local staging="$1" server="${2%/}" link rel name src
  if [[ -z "$(find "$staging" -name '*.jar' \( -type f -o -type l \) -print -quit 2>/dev/null)" ]]; then
    if [[ -d "$server" ]]; then
      echo "[INFO] The archive has no jars (an hourly backup); keeping the current server's jars."
      ( cd "$server" && find . -name '*.jar' -type f -print0 ) |
        while IFS= read -r -d '' rel; do
          mkdir -p -- "$staging/$(dirname "$rel")"
          cp -p -- "$server/$rel" "$staging/$rel"
        done
    fi
    return 0
  fi
  while IFS= read -r -d '' link; do
    [[ -e "$link" ]] && continue   # resolves: a link the server put there itself
    rel="${link#"$staging"/}"
    name="$(basename "$link")"
    src=""
    if [[ -f "$server/$rel" && ! -L "$server/$rel" ]]; then
      src="$server/$rel"
    elif [[ -n "${BACKUPS_PATH:-}" && -f "$BACKUPS_PATH/jars/$name" ]]; then
      src="$BACKUPS_PATH/jars/$name"
    fi
    if [[ -n "$src" ]]; then
      rm -f -- "$link"
      cp -p -- "$src" "$link"
    else
      echo "[WARN] $rel points to a stored jar that no longer exists; the server may not start without it." >&2
    fi
  done < <(find "$staging" -name '*.jar' -type l -print0 2>/dev/null)
  return 0
}

# Set by swap_server_dir while a swap is half done, for swap_recover.
_SWAP_SERVER=""
_SWAP_OLD=""

# swap_recover
# For an EXIT/INT trap (S-031): when a signal lands between the two renames of
# swap_server_dir, the server directory is gone and the original is only at
# <server>.pre-restore.<pid>. Put it back.
swap_recover() {
  if [[ -n "$_SWAP_OLD" && -e "$_SWAP_OLD" && ! -e "$_SWAP_SERVER" ]]; then
    mv -- "$_SWAP_OLD" "$_SWAP_SERVER" \
      && echo "[WARN] Restore interrupted; the original server files were put back." >&2 \
      || _ar_error "Restore interrupted; the original server files are at: $_SWAP_OLD"
  fi
  _SWAP_OLD=""
  _SWAP_SERVER=""
}

# swap_server_dir <staging_dir> <server_dir>
# Replaces <server_dir> with <staging_dir> by renaming, so the server directory
# is either the old contents or the new ones, never a half-written mix. If the
# second rename fails the original is moved back. Both paths must live on the
# same filesystem (the staging directory is created next to the server dir).
#
# With a third argument "keep", the replaced tree is not deleted but renamed to
# <server_dir>.pre-restore (a copy from an earlier run is replaced), so a wrong
# archive can be undone by hand. Without it the old tree is deleted.
swap_server_dir() {
  local staging="$1" server="${2%/}" keep="${3:-}" old
  old="$server.pre-restore.$$"

  _SWAP_SERVER="$server"
  if [[ -e "$server" ]]; then
    chmod --reference="$server" -- "$staging" 2>/dev/null || true
    _SWAP_OLD="$old"
    mv -- "$server" "$old" || { _SWAP_OLD=""; _ar_error "Could not move the current server directory aside"; return 1; }
  fi
  if ! mv -- "$staging" "$server"; then
    _ar_error "Could not move the restored files into place"
    if [[ -e "$old" ]]; then
      mv -- "$old" "$server" || _ar_error "Original server data is preserved at: $old"
    fi
    _SWAP_OLD=""
    return 1
  fi
  _SWAP_OLD=""
  if [[ "$keep" == keep && -e "$old" ]]; then
    rm -rf -- "$server.pre-restore"
    if mv -- "$old" "$server.pre-restore"; then
      echo "[INFO] The previous server files were kept at: $server.pre-restore"
    else
      echo "[WARN] Could not rename the previous server files; they are at: $old" >&2
    fi
    return 0
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
