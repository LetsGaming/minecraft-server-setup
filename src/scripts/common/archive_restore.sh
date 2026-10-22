#!/bin/bash
# Helpers shared by backup/restore.sh and rollback.sh. Source after
# load_variables.sh so BACKUPS_PATH is set. Functions report on stderr and
# return non-zero; they never exit, so callers decide how to unwind.

_ar_error() { echo "[ERROR] $*" >&2; }
_ar_info() { echo "[INFO] $*"; }

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

# list_backup_files <dir> [depth]
# Backup archives under <dir> (exact names only, so partial files, sidecars and
# anything else in the folder are never candidates), newest first by the
# timestamp in the file name; a name without one is placed by its mtime.
# Prints "<epoch> <path>" per line.
list_backup_files() {
  local dir="$1" depth="${2:-1}" file base epoch
  local re='([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})'
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do
    base="${file##*/}"
    if [[ "$base" =~ $re ]]; then
      epoch="$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null)" \
        || epoch="$(stat -c %Y -- "$file" 2>/dev/null || echo 0)"
    else
      epoch="$(stat -c %Y -- "$file" 2>/dev/null || echo 0)"
    fi
    printf '%s %s\n' "$epoch" "$file"
  done < <(find "$dir" -mindepth 1 -maxdepth "$depth" -type f \
             \( -name 'minecraft_backup_*.tar.zst' -o -name 'minecraft_backup_*.tar.gz' \) 2>/dev/null) |
    sort -k1,1nr -k2
}

# validate_archive <file>
# Fails unless the whole archive decompresses and lists cleanly, so a corrupt
# or truncated file is caught before anything on disk is touched. One pass:
# zstd checks the frame checksums while tar lists.
validate_archive() {
  local file="$1"
  case "$file" in
    *.tar.zst)
      ( set -o pipefail; zstd -dc "$file" | tar -tf - >/dev/null ) 2>/dev/null \
        || { _ar_error "Archive failed its integrity check: $file"; return 1; }
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

# archive_format <file>: zst | gz, or failure for anything else.
archive_format() {
  case "$1" in
    *.tar.zst) echo zst ;;
    *.tar.gz) echo gz ;;
    *) _ar_error "Unsupported backup file format: $1"; return 1 ;;
  esac
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

# archive_open_trusted <file>
# Opens the archive once and binds every later check and the extraction to
# that inode (AR_FD), so a file swapped under the same name after the check,
# during the confirmation prompt for example, changes nothing. The opened
# inode must be owned by the running user or root, and may be a hardlink only
# inside archives/ (one archive serves several tiers there).
AR_FD=""
archive_open_trusted() {
  local file="$1" info owner links
  AR_FORMAT="$(archive_format "$file")" || return 1
  exec {AR_FD}<"$file" || { _ar_error "Cannot open $file"; AR_FD=""; return 1; }
  info="$(stat -L -c '%u %h %F' "/dev/fd/$AR_FD" 2>/dev/null)" || info="$(stat -L -c '%u %h %F' -- "$file" 2>/dev/null)" || {
    _ar_error "Cannot read the owner of $file"
    archive_close
    return 1
  }
  owner="${info%% *}"
  links="${info#* }"; links="${links%% *}"
  if [[ "$info" != *"regular"* ]]; then
    _ar_error "Refusing $file: not a regular file"
    archive_close
    return 1
  fi
  if [[ "$owner" != "$(id -u)" && "$owner" != 0 ]]; then
    _ar_error "Refusing $file: it is owned by uid $owner, not by $(id -un). Only archives this user made are restored."
    archive_close
    return 1
  fi
  if [[ "$links" =~ ^[0-9]+$ ]] && (( links > 1 )) && [[ "$file" != "${BACKUPS_PATH%/}/archives/"* ]]; then
    _ar_error "Refusing $file: it has $links hard links and is not under archives/"
    archive_close
    return 1
  fi
  return 0
}

archive_close() {
  if [[ -n "$AR_FD" ]]; then
    exec {AR_FD}<&-
    AR_FD=""
  fi
}

# extract_archive_fd <fd> <format zst|gz> <dest_dir>
# Extracts from an already opened archive into a fresh directory. An archive
# that does not decompress fails here, before anything live is touched, so no
# separate validation pass is needed. On failure the partial directory is
# removed.
extract_archive_fd() {
  local fd="$1" format="$2" dest="$3"
  rm -rf -- "$dest"
  mkdir -p -- "$dest" || return 1
  case "$format" in
    zst) ( set -o pipefail; zstd -dc <&"$fd" | tar -xf - -C "$dest" ) ;;
    gz)  tar -xzf - -C "$dest" <&"$fd" ;;
    *)   _ar_error "Unsupported backup file format"; false ;;
  esac || {
    _ar_error "Extraction failed: the archive does not decompress and unpack cleanly"
    rm -rf -- "$dest"
    return 1
  }
}

# extract_archive <file> <dest_dir>
# Path-based form kept for callers that have not moved to the opened-fd form.
extract_archive() {
  local file="$1" dest="$2" format
  format="$(archive_format "$file")" || return 1
  local fd
  exec {fd}<"$file" || { _ar_error "Cannot open $file"; return 1; }
  local rc=0
  extract_archive_fd "$fd" "$format" "$dest" || rc=1
  exec {fd}<&-
  (( rc == 0 )) || _ar_error "Extraction failed: $file"
  return "$rc"
}

# is_legacy_jar_link <link> <target>
# The exact form backup.sh wrote before S-002: a relative link made of only
# ".." components followed by jars/<the link's own name>.
is_legacy_jar_link() {
  local link="$1" target="$2" name
  name="${link##*/}"
  [[ "$name" == *.jar ]] || return 1
  [[ "$target" =~ ^(\.\./)+jars/([^/]+)$ && "${BASH_REMATCH[2]}" == "$name" ]]
}

# scan_staged_tree <staging_dir> [strict]
# Refuses a restored tree holding a symlink that points outside it (an
# absolute target, or a relative one that escapes), since the server would
# follow it as its own user. The one exception is the legacy jar link
# (is_legacy_jar_link), which complete_staged_jars replaces or removes; with
# "strict" (the pass after that) there is no exception.
scan_staged_tree() {
  local staging="$1" strict="${2:-}" root link target resolved bad=0
  root="$(realpath -m -- "$staging")"
  while IFS= read -r -d '' link; do
    target="$(readlink -- "$link")"
    if [[ "$strict" != strict ]] && is_legacy_jar_link "$link" "$target"; then
      continue
    fi
    if [[ "$target" == /* ]]; then
      _ar_error "Refusing the archive: ${link#"$staging"/} is a symlink to an absolute path ($target)"
      bad=1
      continue
    fi
    resolved="$(realpath -m -- "$(dirname -- "$link")/$target")"
    if [[ "$resolved" != "$root" && "$resolved" != "$root"/* ]]; then
      _ar_error "Refusing the archive: ${link#"$staging"/} is a symlink that leaves the restored tree ($target)"
      bad=1
    fi
  done < <(find "$staging" -type l -print0 2>/dev/null)
  return "$bad"
}

# carry_over_live <server_dir> <staging_dir> <name...>
# Copies entries the archive never contained (logs, crash reports, the event
# ledger) from the live tree into the staged one, when the staged tree lacks
# them, so a restore does not destroy them.
carry_over_live() {
  local server="${1%/}" staging="$2" name
  shift 2
  [[ -d "$server" ]] || return 0
  for name in "$@"; do
    [[ -n "$name" ]] || continue
    [[ "$name" == */* || "$name" == .. ]] && continue
    [[ -e "$server/$name" || -L "$server/$name" ]] || continue
    [[ -e "$staging/$name" || -L "$staging/$name" ]] && continue
    if cp -a --reflink=auto -- "$server/$name" "$staging/$name" 2>/dev/null || cp -a -- "$server/$name" "$staging/$name"; then
      _ar_info "Carried over $name from the current server files"
    else
      echo "[WARN] Could not carry over $name from the current server files" >&2
    fi
  done
  return 0
}

# complete_staged_jars <staging_dir> <server_dir>
# Makes the jars of a restored tree usable before it is swapped in.
#  - S-003: hourly archives leave every *.jar out (server jar, mods,
#    libraries). When the archive holds no jar at all, the current server's
#    jars are carried over at their own paths, so the restored world starts on
#    the same server and mods it ran with.
#  - S-002: archives made before backup.sh kept real jars replaced jars with
#    links into the backups' jars/ folder, which dangle once restored. Every
#    such link is replaced by the real file (the current server's copy at the
#    same path, else the stored copy in jars/) or removed, so no link into
#    the backups folder survives into the live tree.
complete_staged_jars() {
  local staging="$1" server="${2%/}" link rel name src target
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
    target="$(readlink -- "$link")"
    is_legacy_jar_link "$link" "$target" || continue   # anything else is for scan_staged_tree
    rel="${link#"$staging"/}"
    name="$(basename "$link")"
    src=""
    if [[ -f "$server/$rel" && ! -L "$server/$rel" ]]; then
      src="$server/$rel"
    elif [[ -n "${BACKUPS_PATH:-}" && -f "$BACKUPS_PATH/jars/$name" && ! -L "$BACKUPS_PATH/jars/$name" ]]; then
      src="$BACKUPS_PATH/jars/$name"
    fi
    rm -f -- "$link"
    if [[ -n "$src" ]]; then
      cp -p -- "$src" "$link"
    else
      echo "[WARN] $rel pointed to a stored jar that no longer exists; the link was removed and the server may not start without it." >&2
    fi
  done < <(find "$staging" -name '*.jar' -type l -print0 2>/dev/null)
  return 0
}

# archive_name_is_credible <file>
# For an archive chosen by its name rather than by the operator: the name's
# timestamp must be backed by something a renamer cannot forge. Either the
# sidecar for this exact name exists in .meta/ (written by the backup user
# only), or, for an archive from before sidecars, its mtime lies within two
# hours of the stamp in its name. Anyone who can rename files in the backups
# folder could otherwise make an old or planted archive the "newest".
archive_name_is_credible() {
  local file="$1" base rel side stamp epoch mtime diff
  base="${file##*/}"
  rel="${file#"${BACKUPS_PATH%/}"/}"
  side="${BACKUPS_PATH%/}/.meta/${rel}.sha256"
  if [[ -f "$side" ]] && grep -qF -- "  $base" "$side" 2>/dev/null; then
    return 0
  fi
  local re='([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})'
  if [[ "$base" =~ $re ]]; then
    stamp="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
    epoch="$(date -d "$stamp" +%s 2>/dev/null)" || epoch=""
    mtime="$(stat -c %Y -- "$file" 2>/dev/null)" || mtime=""
    if [[ "$epoch" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]]; then
      diff=$(( mtime - epoch )); (( diff < 0 )) && diff=$(( -diff ))
      (( diff <= 7200 )) && return 0
      _ar_error "Refusing to pick $base automatically: its name says $stamp but the file was last written $(( diff / 60 )) minutes away from that and no sidecar vouches for the name. Choose it explicitly with --file if it is the one you want."
      return 1
    fi
  fi
  _ar_error "Refusing to pick $base automatically: no sidecar vouches for the name. Choose it explicitly with --file if it is the one you want."
  return 1
}

# Set by swap_server_dir while a swap is half done, for swap_recover.
_SWAP_SERVER=""
_SWAP_OLD=""
_SWAP_TRASH=""

# swap_recover
# For an EXIT/INT trap (S-031): when a signal lands between the two renames of
# swap_server_dir, the server directory is gone and the original is only at
# <server>.pre-restore.<pid>. Put it back. A trash tree whose deletion was
# interrupted is deleted again.
swap_recover() {
  if [[ -n "$_SWAP_OLD" && -e "$_SWAP_OLD" && ! -e "$_SWAP_SERVER" ]]; then
    mv -- "$_SWAP_OLD" "$_SWAP_SERVER" \
      && echo "[WARN] Restore interrupted; the original server files were put back." >&2 \
      || _ar_error "Restore interrupted; the original server files are at: $_SWAP_OLD"
  fi
  if [[ -n "$_SWAP_TRASH" && -e "$_SWAP_TRASH" ]]; then
    rm -rf -- "$_SWAP_TRASH" 2>/dev/null || true
  fi
  _SWAP_OLD=""
  _SWAP_SERVER=""
  _SWAP_TRASH=""
}

# swap_server_dir <staging_dir> <server_dir> [keep|discard]
# Replaces <server_dir> with <staging_dir> by renaming, so the server directory
# is either the old contents or the new ones, never a half-written mix. If the
# second rename fails the original is moved back. Both paths must live on the
# same filesystem (the staging directory is created next to the server dir).
#
# With "keep" (the default), the replaced tree is renamed to
# <server_dir>.pre-restore (a copy from an earlier run is replaced), so a wrong
# archive can be undone by hand; cleanup_backups.sh removes it after
# RESTORE_KEEP_OLD_DAYS. With "discard" the old tree is deleted.
swap_server_dir() {
  local staging="$1" server="${2%/}" keep="${3:-keep}" old
  old="$server.pre-restore.$$"

  _SWAP_SERVER="$server"
  if [[ -e "$server" ]]; then
    chmod --reference="$server" -- "$staging" 2>/dev/null || true
    # A restore run as root would otherwise hand the server a root-owned tree.
    if [[ "$(id -u)" == 0 ]]; then
      chown --reference="$server" -- "$staging" 2>/dev/null || true
    fi
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
  [[ -e "$old" ]] || return 0
  if [[ "$keep" != discard ]]; then
    _SWAP_TRASH="$server.pre-restore.trash.$$"
    [[ -e "$server.pre-restore" ]] && mv -- "$server.pre-restore" "$_SWAP_TRASH" 2>/dev/null
    if mv -- "$old" "$server.pre-restore"; then
      touch -- "$server.pre-restore" 2>/dev/null || true
      echo "[INFO] The previous server files were kept at: $server.pre-restore"
    else
      echo "[WARN] Could not rename the previous server files; they are at: $old" >&2
    fi
    [[ -e "$_SWAP_TRASH" ]] && rm -rf -- "$_SWAP_TRASH"
    _SWAP_TRASH=""
    return 0
  fi
  # Renamed to a trash name first so an interrupted deletion is finished by
  # swap_recover instead of leaving <server>.pre-restore.<pid> behind forever.
  _SWAP_TRASH="$server.pre-restore.trash.$$"
  mv -- "$old" "$_SWAP_TRASH" 2>/dev/null || _SWAP_TRASH="$old"
  rm -rf -- "$_SWAP_TRASH"
  _SWAP_TRASH=""
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
