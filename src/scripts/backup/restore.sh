#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"
source "$SCRIPT_DIR/../common/archive_restore.sh"
source "$SCRIPT_DIR/../common/utils.sh"
BK_COMPONENT=restore
source "$SCRIPT_DIR/lib/bk_common.sh"
source "$SCRIPT_DIR/lib/bk_state.sh"
source "$SCRIPT_DIR/lib/bk_space.sh"

BASE_BACKUP_DIR="$BACKUPS_PATH"
BACKUP_DIR="$BASE_BACKUP_DIR"
SKIP_CONFIRMATION=false
SPECIFIC_BACKUP=""
RELATIVE_TIME=""
FROM_ARCHIVE=false
INSTALL_UNITS=false
WITH_SCRIPTS=false
DISCARD_OLD=false
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --y                   Skip confirmation prompt"
    echo "  --file <path>         Restore a specific backup: an absolute path inside the backups"
    echo "                        directory, or a name relative to hourly/ (archives/ with --archive)"
    echo "  --ago <duration>      Restore the newest backup taken at or before that long ago"
    echo "                        (e.g. '3h', '15m', '2d'); a match far from the target is refused"
    echo "                        unless --y is given"
    echo "  --archive             Restore from the archive folder instead of hourly snapshots"
    echo "  --install-units       Install the systemd units stored in an archive (with sudo) after"
    echo "                        showing what changes. Without it, units are installed only after"
    echo "                        an interactive confirmation, and skipped when run non-interactively."
    echo "  --with-scripts        Also put back the management scripts stored in an archive"
    echo "                        (asked for when run interactively; skipped otherwise)"
    echo "  --discard-old         Delete the replaced server files instead of keeping them as"
    echo "                        <server>.pre-restore (the default; RESTORE_KEEP_OLD=false does the same)"
    echo "  --keep-old            Accepted for compatibility; keeping the old files is the default"
    echo "  --help                Show this help message and exit"
    echo ""
    echo "The server must be stopped; the restore refuses to run (exit 3) while it is online."
    echo "Run without a terminal (by the API wrapper), it needs --file and --y, and only"
    echo "restores an archive owned by the user running it. --with-scripts and --install-units"
    echo "are refused without a terminal. logs/, crash-reports/ and ledger.sqlite are carried"
    echo "over from the current server files (RESTORE_CARRY_OVER)."
}

# review_and_install_unit <unit-file> <unit-name>
# Units run as root once enabled, so one from an archive is never copied in
# silently: show how it differs from the installed unit, then install only on
# --install-units or an interactive "y". Returns 0 only when it was installed.
review_and_install_unit() {
    local src="$1" name="$2" dest="$SYSTEMD_UNIT_DIR/$2"

    if [[ -f "$dest" ]]; then
        if cmp -s "$src" "$dest"; then
            echo "[INFO]   = $name is unchanged"
            return 1
        fi
        echo "[INFO]   $name differs from the installed unit:"
        diff -u "$dest" "$src" | sed 's/^/           /' || true
    else
        echo "[INFO]   $name is not installed yet. Contents:"
        sed 's/^/           | /' "$src"
    fi

    local approved=false answer
    if $INSTALL_UNITS; then
        approved=true
    elif [[ -t 0 ]]; then
        read -rp "Install $name into $SYSTEMD_UNIT_DIR? (y/N): " answer
        [[ "$answer" =~ ^[Yy]$ ]] && approved=true
    fi

    if ! $approved; then
        echo "[WARN]   ✗ $name NOT installed. Review it, then rerun with --install-units or copy it yourself."
        return 1
    fi

    sudo cp "$src" "$dest"
    sudo chmod 644 "$dest"
    echo "[INFO]   ✓ $dest"
    return 0
}

# normalize_relative_time <Ns|Nm|Nh|Nd|Nw>: prints the number of seconds.
normalize_relative_time() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]+)([smhdw])$ ]]; then
        local value="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            s) echo "$value" ;;
            m) echo $((value * 60)) ;;
            h) echo $((value * 3600)) ;;
            d) echo $((value * 86400)) ;;
            w) echo $((value * 604800)) ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

require_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "$(date +'%F %T') [ERROR] $1 requires a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --y) SKIP_CONFIRMATION=true; shift ;;
        --file) require_value "$@"; SPECIFIC_BACKUP="$2"; shift 2 ;;
        --ago) require_value "$@"; RELATIVE_TIME="$2"; shift 2 ;;
        --archive) FROM_ARCHIVE=true; shift ;;
        --install-units) INSTALL_UNITS=true; shift ;;
        --with-scripts) WITH_SCRIPTS=true; shift ;;
        --keep-old) shift ;;
        --discard-old) DISCARD_OLD=true; shift ;;
        --help) print_help; exit 0 ;;
        *) echo "$(date +'%F %T') [ERROR] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# S-004: run without a terminal (through sudo by the wrapper), nothing may be
# chosen implicitly: not "the newest archive" (which anyone who can write into
# the backups folder decides) and not a "y" read from stdin.
if [[ ! -t 0 ]] && [[ -z "$SPECIFIC_BACKUP" || "$SKIP_CONFIRMATION" != true ]]; then
    echo "$(date +'%F %T') [ERROR] Without a terminal, restore needs both --file <archive> and --y." >&2
    exit 1
fi

if [[ ! -t 0 ]] && { $WITH_SCRIPTS || $INSTALL_UNITS; }; then
    echo "$(date +'%F %T') [ERROR] --with-scripts and --install-units need a terminal." >&2
    exit 1
fi

bk_load_config >/dev/null 2>&1 || true
KEEP_MODE=keep
if $DISCARD_OLD || [[ "${RESTORE_KEEP_OLD:-true}" == false ]]; then
    KEEP_MODE=discard
fi

acquire_operation_lock restore || exit 75

if $FROM_ARCHIVE; then
    BACKUP_DIR="$BASE_BACKUP_DIR/archives"
    SEARCH_DEPTH=2
else
    BACKUP_DIR="$BASE_BACKUP_DIR/hourly"
    SEARCH_DEPTH=1
fi

find_latest_backup() {
    list_backup_files "$BACKUP_DIR" "$SEARCH_DEPTH" | head -n1 | cut -d' ' -f2-
}

# find_backup_by_age <seconds-ago>: the newest backup taken at or before the
# target, by the stamp in its name; the oldest one after it when none is older.
find_backup_by_age() {
    local target=$(( $(date +%s) - $1 )) line epoch file before="" after=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        epoch="${line%% *}"; file="${line#* }"
        if (( epoch <= target )); then
            [[ -z "$before" ]] && before="$epoch $file"
        else
            after="$epoch $file"
        fi
    done < <(list_backup_files "$BACKUP_DIR" "$SEARCH_DEPTH")
    [[ -n "$before" ]] && { echo "$before"; return 0; }
    [[ -n "$after" ]] && { echo "$after"; return 0; }
    return 1
}

if [[ ! -d "$BACKUP_DIR" && -z "$SPECIFIC_BACKUP" ]]; then
    echo "[ERROR] No backups folder at $BACKUP_DIR; nothing to restore from."
    exit 1
fi

if [[ -n "$SPECIFIC_BACKUP" ]]; then
    BACKUP_TO_RESTORE=$(resolve_backup_file "$SPECIFIC_BACKUP" "$BACKUP_DIR") || exit 1
elif [[ -n "$RELATIVE_TIME" ]]; then
    AGO_SECONDS=$(normalize_relative_time "$RELATIVE_TIME") || {
        echo "[ERROR] Invalid time format for --ago: $RELATIVE_TIME"; exit 1;
    }
    CHOICE="$(find_backup_by_age "$AGO_SECONDS")" || { echo "[ERROR] No suitable backup found."; exit 1; }
    CHOSEN_EPOCH="${CHOICE%% *}"
    BACKUP_TO_RESTORE="${CHOICE#* }"
    TARGET_EPOCH=$(( $(date +%s) - AGO_SECONDS ))
    DISTANCE=$(( CHOSEN_EPOCH - TARGET_EPOCH )); (( DISTANCE < 0 )) && DISTANCE=$(( -DISTANCE ))
    echo "[INFO] Requested: $(date -d "@$TARGET_EPOCH" +'%F %T') ($RELATIVE_TIME ago); closest backup: $(date -d "@$CHOSEN_EPOCH" +'%F %T') ($(basename "$BACKUP_TO_RESTORE"))"
    if (( DISTANCE * 2 > AGO_SECONDS )); then
        if $SKIP_CONFIRMATION; then
            echo "[WARN] That backup is $((DISTANCE / 60)) minutes away from the requested time; continuing because of --y."
        else
            echo "[ERROR] The closest backup is $((DISTANCE / 60)) minutes away from the requested time (more than half of $RELATIVE_TIME). Pass --file to choose it explicitly, or --y to accept it."
            exit 1
        fi
    fi
else
    BACKUP_TO_RESTORE=$(find_latest_backup)
fi

[[ -n "${BACKUP_TO_RESTORE:-}" && -e "$BACKUP_TO_RESTORE" ]] || { echo "[ERROR] No suitable backup found."; exit 1; }
# From here on every check and the extraction use the opened inode (S-004).
archive_open_trusted "$BACKUP_TO_RESTORE" || exit 1

echo "[INFO] Selected backup: $BACKUP_TO_RESTORE"

# Replacing the world under a live server corrupts it, so a running server is
# a hard stop. Stop the server first (or use rollback.sh, which does it).
require_server_stopped || exit 3

# The restored tree is unpacked next to the server directory; the kept
# pre-restore copy is only a rename and needs no extra room.
STAGING_PARENT="$(dirname "${SERVER_PATH%/}")"
NEED_BYTES=0
if [[ -d "$SERVER_PATH" ]]; then
    NEED_BYTES="$(du -sb -- "$SERVER_PATH" 2>/dev/null | cut -f1 || echo 0)"
fi
[[ "$NEED_BYTES" =~ ^[0-9]+$ ]] || NEED_BYTES=0
ARCHIVE_BYTES="$(stat -L -c %s "/dev/fd/$AR_FD" 2>/dev/null || stat -c %s -- "$BACKUP_TO_RESTORE" 2>/dev/null || echo 0)"
(( ARCHIVE_BYTES * 3 > NEED_BYTES )) && NEED_BYTES=$(( ARCHIVE_BYTES * 3 ))
AVAIL_BYTES="$(bk_space_available "$STAGING_PARENT" 2>/dev/null || echo "")"
if [[ "$AVAIL_BYTES" =~ ^[0-9]+$ ]] && (( AVAIL_BYTES < NEED_BYTES )); then
    echo "[ERROR] Not enough free space next to $SERVER_PATH: about $(bk_human_bytes "$NEED_BYTES") needed for the restored tree, $(bk_human_bytes "$AVAIL_BYTES") free."
    exit 73
fi

if [[ -d "$SERVER_PATH" && -n "$(ls -A "$SERVER_PATH")" ]]; then
    if [[ "$KEEP_MODE" == keep ]]; then
        echo "[WARN] $SERVER_PATH will be replaced; the current files are kept at ${SERVER_PATH%/}.pre-restore for $RESTORE_KEEP_OLD_DAYS days."
    else
        echo "[WARN] $SERVER_PATH is not empty and will be replaced; the current files are deleted."
    fi
    if [ "$SKIP_CONFIRMATION" = false ]; then
        read -rp "Continue with restore? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "[INFO] Restore aborted."; exit 0; }
    fi
fi

# The archive is unpacked next to the server directory and swapped in only
# once extraction succeeded, so a failure leaves the current world untouched.
STAGING_DIR="${SERVER_PATH%/}.restore-staging.$$"
SWAPPED=false
# Puts the original back if a signal lands mid-swap (S-031), and releases the
# operation lock this trap would otherwise have replaced (S-030). The archive's
# .mc-meta is only removed once the restored tree is live (F21).
_restore_exit() {
    local rc=$?
    trap - EXIT
    swap_recover
    rm -rf -- "$STAGING_DIR"
    $SWAPPED && rm -rf -- "${SERVER_PATH%/}/.mc-meta"
    archive_close
    release_operation_lock
    exit "$rc"
}
trap _restore_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[INFO] Restoring backup..."
extract_archive_fd "$AR_FD" "$AR_FORMAT" "$STAGING_DIR" || exit 1
scan_staged_tree "$STAGING_DIR" || exit 1
# Hourly archives hold no jars, older archives hold dangling jar links (S-002,
# S-003); either way the restored tree gets runnable jars before it goes live.
complete_staged_jars "$STAGING_DIR" "$SERVER_PATH"
# Logs, crash reports and the event ledger are never in a backup (D5); they
# are taken from the live tree so a restore does not destroy them.
# shellcheck disable=SC2086
carry_over_live "$SERVER_PATH" "$STAGING_DIR" ${RESTORE_CARRY_OVER:-}
# Extraction takes a while; confirm nothing started the server in the meantime.
require_server_stopped || exit 3
swap_server_dir "$STAGING_DIR" "$SERVER_PATH" "$KEEP_MODE" || exit 1
SWAPPED=true

echo "[INFO] Server data restored."

# ── restore instance metadata ──
# Archive backups embed a .mc-meta directory containing the scripts tree,
# systemd service files, and api-server-config.json. Restore them now so the
# management infrastructure is fully rebuilt alongside the server data.
META_DIR="$SERVER_PATH/.mc-meta"
if [[ -d "$META_DIR" ]]; then
  echo "[INFO] Restoring instance metadata..."

  INSTANCE_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # <root>/scripts/<instance>
  # The install root, not the server dir's parent (<root>/instances).
  BASE_DIR="$(dirname "$(dirname "$INSTANCE_SCRIPTS_DIR")")"
  TARGET_DIR_NAME="$(basename "$BASE_DIR")"

  # 1. Scripts tree. These run as this user (and some through sudo grants), so
  # they are only replaced when someone asked for it (S-004): --with-scripts,
  # or a "y" at a terminal.
  restore_scripts=$WITH_SCRIPTS
  if [[ -d "$META_DIR/scripts" ]] && ! $restore_scripts && [[ -t 0 ]]; then
    read -rp "Also restore the management scripts stored in the archive? (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]] && restore_scripts=true
  fi
  if [[ -d "$META_DIR/scripts" ]] && ! $restore_scripts; then
    echo "[INFO]   - scripts/ left as they are (pass --with-scripts to restore them)"
  fi
  if [[ -d "$META_DIR/scripts" ]] && $restore_scripts; then
    rsync -a "$META_DIR/scripts/" "$INSTANCE_SCRIPTS_DIR/"
    echo "[INFO]   ✓ scripts/"

    # Reinstall node_modules, which the backup excludes. Only update/ has any
    # since the web interface was retired.
    _update_dir="$INSTANCE_SCRIPTS_DIR/update"
    if [[ -f "$_update_dir/package.json" ]]; then
      echo "[INFO]   npm install in update/..."
      if [[ -f "$_update_dir/package-lock.json" ]]; then _npm=(npm ci); else _npm=(npm install); fi
      "${_npm[@]}" --omit=dev --prefix "$_update_dir" >/dev/null \
        && echo "[INFO]     ✓ update/node_modules" \
        || echo "[WARN]     npm install failed in update/; run manually"
    fi
  fi

  # 2. Systemd service files
  units_installed=false
  if [[ -d "$META_DIR/systemd" ]] && compgen -G "$META_DIR/systemd/*.service" > /dev/null 2>&1; then
    for svc_file in "$META_DIR/systemd/"*.service; do
      [[ -f "$svc_file" ]] || continue
      svc_name="$(basename "$svc_file")"
      # A backup taken before the web interface was retired still carries its
      # unit. Reinstalling it here would quietly bring a retired, credentialed
      # service back up on a host the operator had already cleaned.
      if [[ "$svc_name" == *-manager.service ]]; then
        echo "[INFO]   - skipped $svc_name (the web interface was retired)"
        continue
      fi
      if review_and_install_unit "$svc_file" "$svc_name"; then
        units_installed=true
      fi
    done
    if $units_installed; then
      sudo systemctl daemon-reload
      echo "[INFO]   ✓ systemctl daemon-reload"
    fi
  fi

  # 3. api-server-config.json, into the wrapper's folder (services/api-server/,
  # or api-server/ on an install that predates the services/ layout)
  if [[ -f "$META_DIR/api-server-config.json" ]]; then
    API_DIR="$BASE_DIR/services/api-server"
    [[ ! -d "$API_DIR" && -d "$BASE_DIR/api-server" ]] && API_DIR="$BASE_DIR/api-server"
    mkdir -p "$API_DIR"
    cp "$META_DIR/api-server-config.json" "$API_DIR/api-server-config.json"
    chmod 600 "$API_DIR/api-server-config.json"
    echo "[INFO]   ✓ api-server-config.json -> $API_DIR/"
    echo "[INFO]     If the wrapper runs as its own user (API_SERVER.SERVICE_USER), run"
    echo "[INFO]     src/setup/management/service_user.sh again so it can read the file."
  fi

  # Clean .mc-meta out of the server root: it has no place there at runtime
  rm -rf "$META_DIR"

  echo "[INFO] Metadata restore complete."
  echo ""
  echo "[INFO] Services are never started by a restore."
  echo "[INFO] Review the restored config, then start manually:"
  echo "         sudo systemctl enable --now ${INSTANCE_NAME}.service"
  echo "         sudo systemctl enable --now ${TARGET_DIR_NAME}-api-server.service"
else
  echo "[WARN] No .mc-meta found in archive; metadata not restored."
  echo "       This is expected for hourly backups or archives created before this feature."
fi

echo "[INFO] Restore complete."
