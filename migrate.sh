#!/bin/bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════╗
# ║  Minecraft Server Setup — Migration Script                  ║
# ║                                                             ║
# ║  Upgrades the runtime scripts of an existing server         ║
# ║  installation to the latest version. Does NOT touch:        ║
# ║    - World data, mods, server.jar, server.properties        ║
# ║    - Systemd services, cron jobs                            ║
# ║    - Your variables.txt values (only adds new fields)       ║
# ║    - downloaded_versions.json                               ║
# ║    - interface/  (web interface — preserved and restored)   ║
# ║    - update/node_modules/   (preserved; reinstalled only    ║
# ║      when package.json changes)                             ║
# ║    - api-server/node_modules/, manager/node_modules/        ║
# ║      (preserved; reinstalled only when package.json changes)║
# ║    - JSON config files (e.g. manager/src/config/config.json)║
# ║      (existing values kept; new keys merged in)             ║
# ║    - manager/src/config/users.json  (credentials, untouched)║
# ║    - api-server/api-server-config.json  (untouched)         ║
# ╚══════════════════════════════════════════════════════════════╝

MIGRATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_SCRIPTS_SOURCE="$MIGRATE_SCRIPT_DIR/src/scripts"

# ── Colors ──
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "    $*"; }

# ── Args ──
TARGET_SCRIPTS_DIR=""
SKIP_CONFIRM=false
SKIP_STOP=false
DRY_RUN=false

print_help() {
  cat <<EOF
Usage: $0 <path-to-scripts-dir> [options]

Migrates an existing Minecraft server's runtime scripts to the latest version.

Arguments:
  <path-to-scripts-dir>   Path to the deployed scripts directory.
                          Typically: <target>/scripts/<instance>
                          Example:   /home/mc/minecraft-server/scripts/survival

Options:
  --y          Skip all confirmation prompts
  --no-stop    Don't stop the server before migration
  --dry-run    Show what would be done without making changes
  --help       Show this help

What gets replaced (per-instance scripts):
  - All .sh and .js files (start, shutdown, backup, restore, update, etc.)

What gets updated (root-level shared components):
  - api-server/    at <install-root>/api-server/
  - manager/       at <install-root>/manager/

What is NEVER touched:
  - common/variables.txt          (only new variables are appended)
  - common/downloaded_versions.json
  - interface/                    (web interface — preserved and restored)
  - update/node_modules/          (preserved; reinstalled if package.json changed)
  - api-server/node_modules/, manager/node_modules/  (same)
  - api-server/api-server-config.json   (user config — fully preserved)
  - manager/src/config/config.json      (merged: existing values kept, new keys added)
  - manager/src/config/users.json       (credentials — fully preserved)
  - backup/logs/, logs/
  - World data, mods, server.jar, server.properties
  - Systemd services, cron jobs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --y)       SKIP_CONFIRM=true; shift ;;
    --no-stop) SKIP_STOP=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) print_help; exit 0 ;;
    -*)        err "Unknown option: $1"; print_help; exit 1 ;;
    *)
      if [[ -z "$TARGET_SCRIPTS_DIR" ]]; then TARGET_SCRIPTS_DIR="$1"
      else err "Unexpected argument: $1"; print_help; exit 1; fi
      shift ;;
  esac
done

# ── Validate ──

[[ -z "$TARGET_SCRIPTS_DIR" ]] && { err "Missing required argument."; echo; print_help; exit 1; }

TARGET_SCRIPTS_DIR="$(cd "$TARGET_SCRIPTS_DIR" 2>/dev/null && pwd)" || {
  err "Directory does not exist: $TARGET_SCRIPTS_DIR"; exit 1; }

VARS_FILE="$TARGET_SCRIPTS_DIR/common/variables.txt"
[[ ! -f "$VARS_FILE" ]] && {
  err "Not a valid scripts directory: common/variables.txt not found."
  info "Expected: $VARS_FILE"
  info "Point to the deployed instance dir, e.g.: /home/mc/minecraft-server/scripts/survival"
  exit 1; }

[[ ! -d "$NEW_SCRIPTS_SOURCE" ]] && {
  err "New scripts source not found: $NEW_SCRIPTS_SOURCE"
  info "Run this script from the minecraft-server-setup project root."
  exit 1; }

source "$VARS_FILE"

# BASE_DIR is the install root — one level above the instance server dir
# SERVER_PATH = <install-root>/<instance>, so dirname gives us <install-root>
BASE_DIR="$(dirname "${SERVER_PATH:?SERVER_PATH not set in variables.txt}")"

# Root-level shared components: source name → deployed name at $BASE_DIR/<dst>/
# Parallel arrays (bash 3 compatible)
ROOT_SRC_NAMES=("api-server"          "minecraft-server-manager")
ROOT_DST_NAMES=("api-server"          "manager")

echo
echo -e "${BOLD}Minecraft Server Setup — Migration${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
info "Instance:     ${INSTANCE_NAME:-unknown}"
info "Server path:  ${SERVER_PATH:-unknown}"
info "Install root: $BASE_DIR"
info "Scripts dir:  $TARGET_SCRIPTS_DIR"
info "Source (new): $NEW_SCRIPTS_SOURCE"
echo

# ── Pre-migration checks ──

echo -e "${BOLD}Pre-migration checks${NC}"

REQUIRED_NEW_FILES=(
  "common/server_control.sh"
  "common/load_variables.sh"
  "common/rcon.js"
  "common/webhook.sh"
  "backup/backup.sh"
  "start.sh"
  "shutdown.sh"
  "update/update-server.js"
  "update/update-mods.js"
  "update/check-updates.js"
  "update/package.json"
  "api-server/index.js"
  "api-server/package.json"
)
check_ok=true
for f in "${REQUIRED_NEW_FILES[@]}"; do
  [[ ! -f "$NEW_SCRIPTS_SOURCE/$f" ]] && { err "Missing in new scripts: $f"; check_ok=false; }
done
$check_ok && log "New scripts source is complete" || { err "Aborting."; exit 1; }

# Server status
SERVER_RUNNING=false
if [[ -n "${INSTANCE_NAME:-}" ]]; then
  if screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then
    SERVER_RUNNING=true; warn "Server '$INSTANCE_NAME' is currently running"
  elif systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then
    SERVER_RUNNING=true; warn "Server '$INSTANCE_NAME' is currently running (systemd)"
  else
    log "Server is not running"
  fi
fi

# Compression
USE_ZSTD=false
if command -v zstd &>/dev/null; then
  log "zstd available — backup will use zstd compression"; USE_ZSTD=true
else
  warn "zstd not found — backup will use gzip"
fi

# Disk space
AVAIL_MB=$(df -BM "$TARGET_SCRIPTS_DIR" | tail -1 | awk '{print $4}' | tr -d 'M')
SCRIPTS_SIZE_MB=$(du -sm "$TARGET_SCRIPTS_DIR" | cut -f1)
NEEDED_MB=$(( SCRIPTS_SIZE_MB / 2 + 10 ))
(( AVAIL_MB < NEEDED_MB )) \
  && warn "Low disk space: ${AVAIL_MB}MB available, need ~${NEEDED_MB}MB for backup" \
  || log "Disk space OK (${AVAIL_MB}MB available)"

echo

# ── JSON config merge helpers ──

_count_new_json_keys() {
  local existing="$1" new_file="$2"
  node -e "
    const fs = require('fs');
    const ex = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const nw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    let n = 0;
    function count(t, s) {
      for (const k of Object.keys(s)) {
        if (!(k in t)) { n++; }
        else if (s[k] && typeof s[k] === 'object' && !Array.isArray(s[k]) &&
                 t[k] && typeof t[k] === 'object' && !Array.isArray(t[k])) {
          count(t[k], s[k]);
        }
      }
    }
    count(ex, nw);
    console.log(n);
  " "$existing" "$new_file" 2>/dev/null || echo "0"
}

_merge_json_config() {
  local existing="$1" new_file="$2"
  node -e "
    const fs = require('fs');
    const ex = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const nw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    function merge(target, source) {
      for (const [k, v] of Object.entries(source)) {
        if (!(k in target)) {
          target[k] = v;
        } else if (v && typeof v === 'object' && !Array.isArray(v) &&
                   target[k] && typeof target[k] === 'object' && !Array.isArray(target[k])) {
          merge(target[k], v);
        }
      }
    }
    merge(ex, nw);
    fs.writeFileSync(process.argv[2], JSON.stringify(ex, null, 2) + '\n');
  " "$existing" "$new_file"
}

# ── What will change ──

echo -e "${BOLD}Changes to be applied${NC}"

# Per-instance counters
REPLACED=0; ADDED=0
JSON_CONFIGS=()      # "relpath:new_key_count" — per-instance config.json files
JSON_CONFIG_ADDED=0

# Root-level component counters
ROOT_REPLACED=0; ROOT_ADDED=0; ROOT_JSON_ADDED=0
NEEDS_ROOT_UPDATE=false

# Per-instance npm subdirs (api-server excluded — it's root-level)
HAS_INTERFACE=false
declare -a NPM_SUBDIRS=()
NEEDS_ANY_NPM_INSTALL=false

# ── Per-instance file diff ──

while IFS= read -r f; do
  case "$f" in
    # Always-preserved files
    common/variables.txt|common/downloaded_versions.json) continue ;;
    # Per-instance npm artifacts
    update/node_modules/*) continue ;;
    # Root-level components — handled in their own section below
    api-server/*|minecraft-server-manager/*) continue ;;
    # Git submodule ref files
    */.git|.git) continue ;;
  esac

  target="$TARGET_SCRIPTS_DIR/$f"
  src="$NEW_SCRIPTS_SOURCE/$f"

  # Per-instance JSON config files: merge, don't replace
  if [[ "$f" == */config/config.json ]]; then
    if [[ -f "$target" ]]; then
      nk=$(_count_new_json_keys "$target" "$src")
      if [[ "$nk" -gt 0 ]]; then
        info "MERGE   $f ($nk new key(s))"
        JSON_CONFIGS+=("$f:$nk")
        JSON_CONFIG_ADDED=$(( JSON_CONFIG_ADDED + nk ))
        REPLACED=$(( REPLACED + 1 ))
      else
        info "KEEP    $f (no new keys)"
        JSON_CONFIGS+=("$f:0")
      fi
    else
      info "ADD     $f"; ADDED=$(( ADDED + 1 ))
    fi
    continue
  fi

  if [[ -f "$target" ]]; then
    diff -q "$src" "$target" &>/dev/null || { info "UPDATE  $f"; REPLACED=$(( REPLACED + 1 )); }
  else
    info "ADD     $f"; ADDED=$(( ADDED + 1 ))
  fi
done < <(cd "$NEW_SCRIPTS_SOURCE" && find . -type f | sed 's|^\./||' | sort)

# Per-instance npm subdirs (update only; api-server is root-level)
for subdir in update; do
  src_pkg="$NEW_SCRIPTS_SOURCE/$subdir/package.json"
  dst_dir="$TARGET_SCRIPTS_DIR/$subdir"
  dst_pkg="$dst_dir/package.json"
  dst_modules="$dst_dir/node_modules"

  [[ ! -f "$src_pkg" ]] && continue

  has_modules=false; needs_install=false

  if [[ -d "$dst_modules" ]]; then
    has_modules=true; info "KEEP    ${subdir}/node_modules/  (preserved)"
  fi

  if [[ ! -d "$dst_dir" ]]; then
    needs_install=true
    info "ADD     ${subdir}/  (new — npm install will run)"
  elif ! diff -q "$src_pkg" "$dst_pkg" &>/dev/null 2>&1; then
    needs_install=true; has_modules=false
    info "        (${subdir}/package.json changed — fresh npm install will run)"
  fi

  $needs_install && NEEDS_ANY_NPM_INSTALL=true
  NPM_SUBDIRS+=("${subdir}:${has_modules}:${needs_install}")
done

if [[ -d "$TARGET_SCRIPTS_DIR/interface" ]]; then
  HAS_INTERFACE=true
  info "KEEP    interface/  (web interface — preserved)"
fi

# ── Root-level component diff ──

for i in "${!ROOT_SRC_NAMES[@]}"; do
  src_name="${ROOT_SRC_NAMES[$i]}"
  dst_name="${ROOT_DST_NAMES[$i]}"
  src_dir="$NEW_SCRIPTS_SOURCE/$src_name"
  dst_dir="$BASE_DIR/$dst_name"

  # Skip if source component doesn't exist or component isn't installed yet
  [[ ! -d "$src_dir" ]] && continue
  [[ ! -d "$dst_dir" ]] && continue

  while IFS= read -r f; do
    case "$f" in
      node_modules/*|.git) continue ;;
    esac

    src_file="$src_dir/$f"
    dst_file="$dst_dir/$f"
    display="$dst_name/$f"

    # config.json: merge
    if [[ "$f" == */config/config.json ]]; then
      if [[ -f "$dst_file" ]]; then
        nk=$(_count_new_json_keys "$dst_file" "$src_file")
        if [[ "$nk" -gt 0 ]]; then
          info "MERGE   $display ($nk new key(s))"
          ROOT_JSON_ADDED=$(( ROOT_JSON_ADDED + nk ))
          ROOT_REPLACED=$(( ROOT_REPLACED + 1 ))
          NEEDS_ROOT_UPDATE=true
        else
          info "KEEP    $display (no new keys)"
        fi
      else
        info "ADD     $display"; ROOT_ADDED=$(( ROOT_ADDED + 1 ))
        NEEDS_ROOT_UPDATE=true
      fi
      continue
    fi

    if [[ -f "$dst_file" ]]; then
      diff -q "$src_file" "$dst_file" &>/dev/null || {
        info "UPDATE  $display"
        ROOT_REPLACED=$(( ROOT_REPLACED + 1 ))
        NEEDS_ROOT_UPDATE=true
      }
    else
      info "ADD     $display"
      ROOT_ADDED=$(( ROOT_ADDED + 1 ))
      NEEDS_ROOT_UPDATE=true
    fi
  done < <(cd "$src_dir" && find . -type f | sed 's|^\./||' | sort)

  # Node modules
  [[ -d "$dst_dir/node_modules" ]] && info "KEEP    ${dst_name}/node_modules/  (preserved)"
done

# ── New variables ──

NEW_VARS=()
NEW_VAR_DEFAULTS=(
  'USE_RCON="false"'
  'RCON_HOST="localhost"'
  'RCON_PORT="25575"'
  'RCON_PASSWORD=""'
  'WEBHOOK_URL=""'
  'WEBHOOK_EVENTS=""'
  'RESTART_ENABLED="false"'
  'RESTART_INTERVAL_HOURS="12"'
  'RESTART_SKIP_IF_EMPTY="true"'
  'RESTART_WARN_SECONDS="30"'
  'API_SERVER_ENABLED="false"'
  'API_SERVER_PORT="3000"'
  'API_SERVER_KEY=""'
)
for entry in "${NEW_VAR_DEFAULTS[@]}"; do
  varname="${entry%%=*}"
  if ! grep -q "^${varname}=" "$VARS_FILE" 2>/dev/null; then
    NEW_VARS+=("$entry"); info "ADD VAR $varname"
  fi
done

TOTAL_CHANGES=$(( REPLACED + ADDED + ROOT_REPLACED + ROOT_ADDED ))
if [[ $TOTAL_CHANGES -eq 0 && ${#NEW_VARS[@]} -eq 0 && "$NEEDS_ANY_NPM_INSTALL" != true ]]; then
  log "Everything is already up to date. Nothing to do."
  exit 0
fi

echo
SUMMARY="$REPLACED file(s) to update, $ADDED file(s) to add, ${#NEW_VARS[@]} variable(s) to add"
[[ $(( ROOT_REPLACED + ROOT_ADDED )) -gt 0 ]] && \
  SUMMARY="$SUMMARY, $ROOT_REPLACED root-level file(s) to update"
[[ $(( JSON_CONFIG_ADDED + ROOT_JSON_ADDED )) -gt 0 ]] && \
  SUMMARY="$SUMMARY, $(( JSON_CONFIG_ADDED + ROOT_JSON_ADDED )) config key(s) to merge"
info "$SUMMARY"
echo

# ── Confirm ──

if [[ "$SKIP_CONFIRM" != true ]]; then
  echo -e "${BOLD}This will:${NC}"
  echo "  1. Create a compressed archive backup of the scripts dir"
  $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] && echo "  2. Stop the server"
  echo "  3. Replace per-instance script files"
  echo "     Preserving: variables.txt, downloaded_versions.json, interface/,"
  echo "                 update/node_modules/, logs/"
  if [[ ${#JSON_CONFIGS[@]} -gt 0 ]]; then
    for entry in "${JSON_CONFIGS[@]}"; do
      f="${entry%%:*}"; nk="${entry##*:}"
      [[ "$nk" -gt 0 ]] \
        && echo "     Merging (not replacing): $f  ($nk new key(s))" \
        || echo "     Keeping unchanged: $f"
    done
  fi
  if $NEEDS_ROOT_UPDATE; then
    echo "  4. Update root-level components:"
    for i in "${!ROOT_DST_NAMES[@]}"; do
      dst_dir="$BASE_DIR/${ROOT_DST_NAMES[$i]}"
      [[ -d "$dst_dir" ]] && echo "       $dst_dir"
    done
    echo "     Preserving: node_modules/, api-server-config.json,"
    echo "                 manager/src/config/users.json"
    echo "     Merging (not replacing): manager/src/config/config.json"
  fi
  echo "  5. Add ${#NEW_VARS[@]} new variable(s) to variables.txt"
  $NEEDS_ANY_NPM_INSTALL && echo "  6. Run npm install in changed per-instance subdirs"
  $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] && echo "  7. Restart the server"
  echo
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  echo
fi

run_cmd() {
  $DRY_RUN && echo "[DRY-RUN] $*" || "$@"
}

# ── Step 1: Compressed archive backup ──

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PARENT="$(dirname "$TARGET_SCRIPTS_DIR")"
BACKUP_BASE="$(basename "$TARGET_SCRIPTS_DIR")_backup_${BACKUP_TIMESTAMP}"

echo -e "${BOLD}Step 1: Backup${NC}"
if $USE_ZSTD; then
  BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.zst"
  log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
  run_cmd tar -C "$BACKUP_PARENT" -I 'zstd -3' -cf "$BACKUP_ARCHIVE" "$(basename "$TARGET_SCRIPTS_DIR")"
else
  BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.gz"
  log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
  run_cmd tar -C "$BACKUP_PARENT" -czf "$BACKUP_ARCHIVE" "$(basename "$TARGET_SCRIPTS_DIR")"
fi
[[ -f "$BACKUP_ARCHIVE" ]] && info "Archive size: $(du -sk "$BACKUP_ARCHIVE" | cut -f1)KB"

# ── Step 2: Stop server ──

if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]]; then
  echo; echo -e "${BOLD}Step 2: Stop server${NC}"
  log "Stopping '$INSTANCE_NAME'..."
  if ! $DRY_RUN; then
    if screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then
      if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$USER" screen -S "$INSTANCE_NAME" -p 0 -X stuff "/say Server updating scripts. Restarting shortly.$(printf \\r)" 2>/dev/null || true
      else
        screen -S "$INSTANCE_NAME" -p 0 -X stuff "/say Server updating scripts. Restarting shortly.$(printf \\r)" 2>/dev/null || true
      fi
      sleep 3
    fi
  fi
  run_cmd sudo systemctl stop "${INSTANCE_NAME}.service" 2>/dev/null || true
  sleep 2; log "Server stopped"
else
  $SERVER_RUNNING && warn "Server running but --no-stop specified. Scripts replaced live."
fi

# ── Step 3: Replace per-instance scripts ──

echo; echo -e "${BOLD}Step 3: Replace per-instance scripts${NC}"

PRESERVE_DIR=$(mktemp -d)

# Save files that must survive the wipe
for pf in "common/variables.txt" "common/downloaded_versions.json"; do
  [[ -f "$TARGET_SCRIPTS_DIR/$pf" ]] && {
    run_cmd mkdir -p "$PRESERVE_DIR/$(dirname "$pf")"
    run_cmd cp -a "$TARGET_SCRIPTS_DIR/$pf" "$PRESERVE_DIR/$pf"
  }
done

for logdir in "backup/logs" "logs"; do
  [[ -d "$TARGET_SCRIPTS_DIR/$logdir" ]] && {
    run_cmd mkdir -p "$PRESERVE_DIR/$logdir"
    run_cmd cp -a "$TARGET_SCRIPTS_DIR/$logdir/." "$PRESERVE_DIR/$logdir/"
  }
done

if $HAS_INTERFACE; then
  run_cmd mkdir -p "$PRESERVE_DIR/interface"
  run_cmd cp -a "$TARGET_SCRIPTS_DIR/interface/." "$PRESERVE_DIR/interface/"
  info "Saved: interface/"
fi

for entry in "${NPM_SUBDIRS[@]}"; do
  subdir="${entry%%:*}"; rest="${entry#*:}"
  has_modules="${rest%%:*}"; needs_install="${rest##*:}"
  if [[ "$has_modules" == true && "$needs_install" == false ]]; then
    run_cmd mkdir -p "$PRESERVE_DIR/$subdir"
    run_cmd cp -a "$TARGET_SCRIPTS_DIR/$subdir/node_modules" "$PRESERVE_DIR/$subdir/node_modules"
    info "Saved: ${subdir}/node_modules/"
  fi
done

# Per-instance JSON config files
for entry in "${JSON_CONFIGS[@]:-}"; do
  [[ -z "$entry" ]] && continue
  f="${entry%%:*}"
  [[ -f "$TARGET_SCRIPTS_DIR/$f" ]] && {
    run_cmd mkdir -p "$PRESERVE_DIR/$(dirname "$f")"
    run_cmd cp -a "$TARGET_SCRIPTS_DIR/$f" "$PRESERVE_DIR/$f"
    info "Saved: $f"
  }
done

# Wipe and replace
log "Removing old per-instance scripts..."
$DRY_RUN || find "$TARGET_SCRIPTS_DIR" -mindepth 1 -delete
log "Copying new per-instance scripts..."
$DRY_RUN || cp -a "$NEW_SCRIPTS_SOURCE/." "$TARGET_SCRIPTS_DIR/"

# Remove root-level component source trees that got copied into the scripts dir
# (they're submodules in src/scripts/ but don't belong inside scripts/INSTANCE_NAME/)
for src_name in "${ROOT_SRC_NAMES[@]}"; do
  [[ -d "$TARGET_SCRIPTS_DIR/$src_name" ]] && {
    $DRY_RUN || rm -rf "$TARGET_SCRIPTS_DIR/$src_name"
  }
done

# Restore preserved files
log "Restoring preserved files..."

for pf in "common/variables.txt" "common/downloaded_versions.json"; do
  [[ -f "$PRESERVE_DIR/$pf" ]] && {
    $DRY_RUN || { mkdir -p "$TARGET_SCRIPTS_DIR/$(dirname "$pf")"; cp -a "$PRESERVE_DIR/$pf" "$TARGET_SCRIPTS_DIR/$pf"; }
    info "Restored: $pf"
  }
done

for logdir in "backup/logs" "logs"; do
  [[ -d "$PRESERVE_DIR/$logdir" ]] && {
    $DRY_RUN || { mkdir -p "$TARGET_SCRIPTS_DIR/$logdir"; cp -a "$PRESERVE_DIR/$logdir/." "$TARGET_SCRIPTS_DIR/$logdir/"; }
    info "Restored: $logdir/"
  }
done

if [[ -d "$PRESERVE_DIR/interface" ]]; then
  $DRY_RUN || { mkdir -p "$TARGET_SCRIPTS_DIR/interface"; cp -a "$PRESERVE_DIR/interface/." "$TARGET_SCRIPTS_DIR/interface/"; }
  info "Restored: interface/"
fi

for entry in "${NPM_SUBDIRS[@]}"; do
  subdir="${entry%%:*}"; rest="${entry#*:}"
  has_modules="${rest%%:*}"; needs_install="${rest##*:}"
  if [[ "$has_modules" == true && "$needs_install" == false ]] && [[ -d "$PRESERVE_DIR/$subdir/node_modules" ]]; then
    $DRY_RUN || { mkdir -p "$TARGET_SCRIPTS_DIR/$subdir"; cp -a "$PRESERVE_DIR/$subdir/node_modules" "$TARGET_SCRIPTS_DIR/$subdir/node_modules"; }
    info "Restored: ${subdir}/node_modules/"
  fi
done

for entry in "${JSON_CONFIGS[@]:-}"; do
  [[ -z "$entry" ]] && continue
  f="${entry%%:*}"; nk="${entry##*:}"
  preserved="$PRESERVE_DIR/$f"
  deployed="$TARGET_SCRIPTS_DIR/$f"
  [[ ! -f "$preserved" ]] && continue
  if [[ "$nk" -gt 0 ]]; then
    if command -v node &>/dev/null; then
      $DRY_RUN || _merge_json_config "$preserved" "$deployed"
      info "Merged: $f ($nk new key(s))"
    else
      $DRY_RUN || cp -a "$preserved" "$deployed"
      warn "node not found — kept existing $f (new keys not merged)"
    fi
  else
    $DRY_RUN || cp -a "$preserved" "$deployed"
    info "Restored: $f (no new keys)"
  fi
done

rm -rf "$PRESERVE_DIR"
log "Per-instance scripts replaced"

# ── Step 4: Update root-level components ──

if $NEEDS_ROOT_UPDATE; then
  echo; echo -e "${BOLD}Step 4: Update root-level components${NC}"

  for i in "${!ROOT_SRC_NAMES[@]}"; do
    src_name="${ROOT_SRC_NAMES[$i]}"
    dst_name="${ROOT_DST_NAMES[$i]}"
    src_dir="$NEW_SCRIPTS_SOURCE/$src_name"
    dst_dir="$BASE_DIR/$dst_name"

    [[ ! -d "$src_dir" || ! -d "$dst_dir" ]] && continue

    log "Updating $dst_name/ ($dst_dir)"

    ROOT_PRESERVE=$(mktemp -d)

    # node_modules
    if [[ -d "$dst_dir/node_modules" ]]; then
      $DRY_RUN || cp -a "$dst_dir/node_modules" "$ROOT_PRESERVE/node_modules"
      info "  Saved: node_modules/"
    fi

    # api-server-config.json (api-server only — user-generated, never in source)
    if [[ -f "$dst_dir/api-server-config.json" ]]; then
      $DRY_RUN || cp -a "$dst_dir/api-server-config.json" "$ROOT_PRESERVE/api-server-config.json"
      info "  Saved: api-server-config.json"
    fi

    # config.json (for merge)
    if [[ -f "$dst_dir/src/config/config.json" ]]; then
      $DRY_RUN || { mkdir -p "$ROOT_PRESERVE/src/config"; cp -a "$dst_dir/src/config/config.json" "$ROOT_PRESERVE/src/config/config.json"; }
    fi

    # users.json (credentials — preserve entirely, never overwrite)
    if [[ -f "$dst_dir/src/config/users.json" ]]; then
      $DRY_RUN || { mkdir -p "$ROOT_PRESERVE/src/config"; cp -a "$dst_dir/src/config/users.json" "$ROOT_PRESERVE/src/config/users.json"; }
      info "  Saved: src/config/users.json"
    fi

    # logs
    if [[ -d "$dst_dir/logs" ]]; then
      $DRY_RUN || { mkdir -p "$ROOT_PRESERVE/logs"; cp -a "$dst_dir/logs/." "$ROOT_PRESERVE/logs/"; }
    fi

    # Wipe and replace
    $DRY_RUN || find "$dst_dir" -mindepth 1 -delete
    $DRY_RUN || cp -a "$src_dir/." "$dst_dir/"

    # Restore node_modules
    if [[ -d "$ROOT_PRESERVE/node_modules" ]]; then
      $DRY_RUN || cp -a "$ROOT_PRESERVE/node_modules" "$dst_dir/node_modules"
      info "  Restored: node_modules/"
    fi

    # Restore api-server-config.json
    if [[ -f "$ROOT_PRESERVE/api-server-config.json" ]]; then
      $DRY_RUN || cp -a "$ROOT_PRESERVE/api-server-config.json" "$dst_dir/api-server-config.json"
      info "  Restored: api-server-config.json"
    fi

    # Merge or restore config.json
    if [[ -f "$ROOT_PRESERVE/src/config/config.json" && -f "$dst_dir/src/config/config.json" ]]; then
      if command -v node &>/dev/null; then
        nk=$(_count_new_json_keys "$ROOT_PRESERVE/src/config/config.json" "$dst_dir/src/config/config.json")
        if [[ "$nk" -gt 0 ]]; then
          $DRY_RUN || _merge_json_config "$ROOT_PRESERVE/src/config/config.json" "$dst_dir/src/config/config.json"
          info "  Merged: src/config/config.json ($nk new key(s))"
        else
          $DRY_RUN || cp -a "$ROOT_PRESERVE/src/config/config.json" "$dst_dir/src/config/config.json"
          info "  Restored: src/config/config.json (no new keys)"
        fi
      else
        $DRY_RUN || cp -a "$ROOT_PRESERVE/src/config/config.json" "$dst_dir/src/config/config.json"
        warn "  node not found — kept existing src/config/config.json"
      fi
    fi

    # Restore users.json (never merge — always preserve as-is)
    if [[ -f "$ROOT_PRESERVE/src/config/users.json" ]]; then
      $DRY_RUN || { mkdir -p "$dst_dir/src/config"; cp -a "$ROOT_PRESERVE/src/config/users.json" "$dst_dir/src/config/users.json"; }
      info "  Restored: src/config/users.json"
    fi

    # Restore logs
    if [[ -d "$ROOT_PRESERVE/logs" ]]; then
      $DRY_RUN || { mkdir -p "$dst_dir/logs"; cp -a "$ROOT_PRESERVE/logs/." "$dst_dir/logs/"; }
    fi

    rm -rf "$ROOT_PRESERVE"

    # npm install if package.json changed or node_modules missing
    if [[ -f "$src_dir/package.json" ]]; then
      needs_npm=false
      if ! diff -q "$src_dir/package.json" "$dst_dir/package.json" &>/dev/null 2>&1; then
        needs_npm=true
      elif [[ ! -d "$dst_dir/node_modules" ]]; then
        needs_npm=true
      fi
      if $needs_npm; then
        if command -v npm &>/dev/null; then
          log "  npm install --omit=dev in $dst_name/"
          run_cmd npm install --omit=dev --prefix "$dst_dir"
        else
          warn "  npm not found — run: npm install --omit=dev --prefix '$dst_dir'"
        fi
      fi
    fi

    log "  $dst_name/ updated"
  done
fi

# ── Step 5: Merge new variables ──

echo; echo -e "${BOLD}Step 5: Update variables.txt${NC}"

if [[ ${#NEW_VARS[@]} -gt 0 ]]; then
  if ! $DRY_RUN; then
    { echo ""; echo "# ── Added by migration $(date +%Y-%m-%d) ──"
      for entry in "${NEW_VARS[@]}"; do echo "$entry"; done
    } >> "$VARS_FILE"
  fi
  log "Added ${#NEW_VARS[@]} new variable(s)"
  for entry in "${NEW_VARS[@]}"; do info "  ${entry%%=*} = ${entry#*=}"; done
else
  log "variables.txt already has all required variables"
fi

# ── Step 6: npm install in changed per-instance subdirs ──

if $NEEDS_ANY_NPM_INSTALL; then
  echo; echo -e "${BOLD}Step 6: Install npm dependencies${NC}"
  if command -v npm &>/dev/null; then
    for entry in "${NPM_SUBDIRS[@]}"; do
      subdir="${entry%%:*}"; needs_install="${entry##*:}"
      [[ "$needs_install" != true ]] && continue
      dir="$TARGET_SCRIPTS_DIR/$subdir"
      [[ -f "$dir/package.json" ]] || continue
      log "npm install --omit=dev in ${subdir}/"
      run_cmd npm install --omit=dev --prefix "$dir"
    done
    log "Dependencies installed"
  else
    warn "npm not found — run manually:"
    for entry in "${NPM_SUBDIRS[@]}"; do
      subdir="${entry%%:*}"; needs_install="${entry##*:}"
      [[ "$needs_install" == true ]] && info "  npm install --omit=dev --prefix '$TARGET_SCRIPTS_DIR/$subdir'"
    done
  fi
fi

# ── Step 7: Verify ──

echo; echo -e "${BOLD}Step 7: Verify${NC}"

verify_ok=true

for f in "common/server_control.sh" "common/load_variables.sh" "common/variables.txt" \
         "backup/backup.sh" "start.sh" \
         "common/rcon.js" "common/webhook.sh" "rollback.sh" "smart_restart.sh" "manage.sh" \
         "update/update-server.js" "update/update-mods.js" "update/check-updates.js" "update/package.json"; do
  [[ -f "$TARGET_SCRIPTS_DIR/$f" ]] && info "✓ $f" || { err "Missing: $f"; verify_ok=false; }
done

$HAS_INTERFACE && {
  [[ -d "$TARGET_SCRIPTS_DIR/interface" ]] \
    && info "✓ interface/ (preserved)" \
    || { err "interface/ was not restored"; verify_ok=false; }
}

for entry in "${JSON_CONFIGS[@]:-}"; do
  [[ -z "$entry" ]] && continue
  f="${entry%%:*}"; cfg="$TARGET_SCRIPTS_DIR/$f"
  [[ -f "$cfg" ]] && \
    node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$cfg" 2>/dev/null \
    && info "✓ $f (valid JSON)" \
    || { err "$f is not valid JSON"; verify_ok=false; }
done

bash -c "source '$VARS_FILE'" 2>/dev/null \
  && info "✓ variables.txt loads correctly" \
  || { err "variables.txt has syntax errors"; verify_ok=false; }

for var in USER INSTANCE_NAME SERVER_PATH BACKUPS_PATH; do
  val=$(bash -c "source '$VARS_FILE' && echo \"\$$var\"" 2>/dev/null)
  [[ -n "$val" ]] && info "✓ $var = $val" || { err "$var missing in variables.txt"; verify_ok=false; }
done

if ! $verify_ok; then
  echo; err "Verification failed. Restore with:"
  info "  rm -rf '$TARGET_SCRIPTS_DIR'"
  info "  tar -C '$(dirname "$TARGET_SCRIPTS_DIR")' -xf '$BACKUP_ARCHIVE'"
  exit 1
fi
log "Verification passed"

# ── Step 8: Restart server ──

if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]]; then
  echo; echo -e "${BOLD}Step 8: Restart server${NC}"
  log "Starting '$INSTANCE_NAME'..."
  run_cmd sudo systemctl start "${INSTANCE_NAME}.service"
  if ! $DRY_RUN; then
    sleep 5
    if systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then log "Server is running"
    elif screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then log "Server is running (screen)"
    else warn "Server may still be starting. Check: systemctl status ${INSTANCE_NAME}.service"; fi
  fi
fi

# ── Done ──

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}${BOLD}Migration complete!${NC}"
echo
info "Backup archive: $BACKUP_ARCHIVE"
info "Remove once verified: rm -f '$BACKUP_ARCHIVE'"
echo
if $NEEDS_ROOT_UPDATE; then
  warn "api-server and manager services were updated but not restarted."
  info "Restart them to pick up the new code:"
  for i in "${!ROOT_DST_NAMES[@]}"; do
    dst_dir="$BASE_DIR/${ROOT_DST_NAMES[$i]}"
    [[ -d "$dst_dir" ]] && {
      svc_pattern="$(basename "$BASE_DIR")-${ROOT_DST_NAMES[$i]}.service"
      info "  sudo systemctl restart $svc_pattern"
    }
  done
  echo
fi
if [[ ${#NEW_VARS[@]} -gt 0 ]]; then
  info "New features available — edit variables.txt to enable:"
  [[ " ${NEW_VARS[*]} " == *"USE_RCON"* ]]           && info "  • RCON:               USE_RCON=\"true\", RCON_PASSWORD"
  [[ " ${NEW_VARS[*]} " == *"WEBHOOK_URL"* ]]         && info "  • Webhooks:           WEBHOOK_URL=\"https://discord.com/...\""
  [[ " ${NEW_VARS[*]} " == *"RESTART_ENABLED"* ]]     && info "  • Scheduled restarts: RESTART_ENABLED=\"true\""
  [[ " ${NEW_VARS[*]} " == *"API_SERVER_ENABLED"* ]]  && info "  • minecraft-bot API:  API_SERVER_ENABLED=\"true\", API_SERVER_KEY"
  echo
fi
info "Scripts available:"
info "  • rollback.sh               — Roll back to pre-update backup"
info "  • smart_restart.sh          — Player-aware restart"
info "  • manage.sh                 — Multi-instance management"
info "  • update/update-server.js   — Update server + mods"
info "  • api-server/index.js       — minecraft-bot HTTP API wrapper"
echo