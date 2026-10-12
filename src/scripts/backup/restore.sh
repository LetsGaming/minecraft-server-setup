#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"
source "$SCRIPT_DIR/../common/archive_restore.sh"
source "$SCRIPT_DIR/../common/utils.sh"

BASE_BACKUP_DIR="$BACKUPS_PATH"
BACKUP_DIR="$BASE_BACKUP_DIR"
SKIP_CONFIRMATION=false
SPECIFIC_BACKUP=""
RELATIVE_TIME=""
FROM_ARCHIVE=false
INSTALL_UNITS=false
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --y                   Skip confirmation prompt"
    echo "  --file <path>         Restore a specific backup: an absolute path inside the backups"
    echo "                        directory, or a name relative to hourly/ (archives/ with --archive)"
    echo "  --ago <duration>      Restore backup closest to specified time ago (e.g. '3h', '15m', '2d')"
    echo "  --archive             Restore from the archive folder instead of hourly snapshots"
    echo "  --install-units       Install the systemd units stored in an archive (with sudo) after"
    echo "                        showing what changes. Without it, units are installed only after"
    echo "                        an interactive confirmation, and skipped when run non-interactively."
    echo "  --help                Show this help message and exit"
    echo ""
    echo "The server must be stopped; the restore refuses to run (exit 3) while it is online."
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

normalize_relative_time() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]+)([smhdw])$ ]]; then
        local value="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "$unit" in
            s) echo "$value seconds ago" ;;
            m) echo "$value minutes ago" ;;
            h) echo "$value hours ago" ;;
            d) echo "$value days ago" ;;
            w) echo "$value weeks ago" ;;
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
        --help) print_help; exit 0 ;;
        *) echo "$(date +'%F %T') [ERROR] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

acquire_operation_lock restore || exit 75

if $FROM_ARCHIVE; then
    BACKUP_DIR="$BASE_BACKUP_DIR/archives"
else
    BACKUP_DIR="$BASE_BACKUP_DIR/hourly"
fi

find_latest_backup() {
    find "$BACKUP_DIR" -maxdepth 2 -type f \( -name '*.tar.*' \) -printf '%T@ %p\n' |
        sort -nr | head -n1 | cut -d' ' -f2-
}

find_closest_backup_by_time() {
    local target_ts="$1"
    find "$BACKUP_DIR" -maxdepth 2 -type f \( -name '*.tar.*' \) -printf '%T@ %p\n' |
        awk -v tgt="$target_ts" '{ diff = ($1 - tgt); if (diff < 0) diff = -diff; print diff, $0; }' |
        sort -n | head -n1 | cut -d' ' -f3-
}

if [[ -n "$SPECIFIC_BACKUP" ]]; then
    BACKUP_TO_RESTORE=$(resolve_backup_file "$SPECIFIC_BACKUP" "$BACKUP_DIR") || exit 1
elif [[ -n "$RELATIVE_TIME" ]]; then
    HUMAN_TIME=$(normalize_relative_time "$RELATIVE_TIME") || {
        echo "[ERROR] Invalid time format for --ago: $RELATIVE_TIME"; exit 1;
    }
    TARGET_TIMESTAMP=$(date -d "$HUMAN_TIME" +%s) || {
        echo "[ERROR] Failed to parse relative time: $RELATIVE_TIME"; exit 1;
    }
    BACKUP_TO_RESTORE=$(find_closest_backup_by_time "$TARGET_TIMESTAMP")
else
    BACKUP_TO_RESTORE=$(find_latest_backup)
fi

[[ -e "$BACKUP_TO_RESTORE" ]] || { echo "[ERROR] No suitable backup found."; exit 1; }

echo "[INFO] Selected backup: $BACKUP_TO_RESTORE"

# Replacing the world under a live server corrupts it, so a running server is
# a hard stop. Stop the server first (or use rollback.sh, which does it).
require_server_stopped || exit 3

echo "[INFO] Validating archive..."
validate_archive "$BACKUP_TO_RESTORE" || exit 1

if [[ -d "$SERVER_PATH" && -n "$(ls -A "$SERVER_PATH")" ]]; then
    echo "[WARN] $SERVER_PATH is not empty and will be replaced."
    if [ "$SKIP_CONFIRMATION" = false ]; then
        read -rp "Continue with restore? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "[INFO] Restore aborted."; exit 0; }
    fi
fi

# The archive is unpacked next to the server directory and swapped in only
# once extraction succeeded, so a failure leaves the current world untouched.
STAGING_DIR="${SERVER_PATH%/}.restore-staging.$$"
trap 'rm -rf -- "$STAGING_DIR"' EXIT

echo "[INFO] Restoring backup..."
extract_archive "$BACKUP_TO_RESTORE" "$STAGING_DIR" || exit 1
# Extraction takes a while; confirm nothing started the server in the meantime.
require_server_stopped || exit 3
swap_server_dir "$STAGING_DIR" "$SERVER_PATH" || exit 1

echo "[INFO] Server data restored."

# ——— restore instance metadata ———
# Archive backups embed a .mc-meta directory containing the scripts tree,
# systemd service files, and api-server-config.json. Restore them now so the
# management infrastructure is fully rebuilt alongside the server data.
META_DIR="$SERVER_PATH/.mc-meta"
if [[ -d "$META_DIR" ]]; then
  echo "[INFO] Restoring instance metadata..."

  BASE_DIR="$(dirname "$SERVER_PATH")"
  TARGET_DIR_NAME="$(basename "$BASE_DIR")"
  INSTANCE_SCRIPTS_DIR="$SCRIPT_DIR/.."

  # 1. Scripts tree
  if [[ -d "$META_DIR/scripts" ]]; then
    rsync -a "$META_DIR/scripts/" "$INSTANCE_SCRIPTS_DIR/"
    echo "[INFO]   ✓ scripts/"

    # Reinstall node_modules, which the backup excludes. Only update/ has any
    # since the web interface was retired — a loop over one entry was left
    # behind by that removal and shellcheck was right to object.
    _update_dir="$INSTANCE_SCRIPTS_DIR/update"
    if [[ -f "$_update_dir/package.json" ]]; then
      echo "[INFO]   npm install in update/..."
      npm install --omit=dev --prefix "$_update_dir" >/dev/null \
        && echo "[INFO]     ✓ update/node_modules" \
        || echo "[WARN]     npm install failed in update/ — run manually"
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
        echo "[INFO]   — skipped $svc_name (the web interface was retired)"
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

  # 3. api-server-config.json
  if [[ -f "$META_DIR/api-server-config.json" ]]; then
    mkdir -p "$BASE_DIR/api-server"
    cp "$META_DIR/api-server-config.json" "$BASE_DIR/api-server/api-server-config.json"
    chmod 600 "$BASE_DIR/api-server/api-server-config.json"
    echo "[INFO]   ✓ api-server-config.json"
  fi

  # Clean .mc-meta out of the server root — it has no place there at runtime
  rm -rf "$META_DIR"

  echo "[INFO] Metadata restore complete."
  echo ""
  echo "[INFO] Services are never started by a restore."
  echo "[INFO] Review the restored config, then start manually:"
  echo "         sudo systemctl enable --now ${INSTANCE_NAME}.service"
  echo "         sudo systemctl enable --now ${TARGET_DIR_NAME}-api-server.service"
else
  echo "[WARN] No .mc-meta found in archive — metadata not restored."
  echo "       This is expected for hourly backups or archives created before this feature."
fi

echo "[INFO] Restore complete."