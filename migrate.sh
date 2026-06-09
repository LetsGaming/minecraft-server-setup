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
# ║    - update/node_modules/                                   ║
# ║      (preserved; reinstalled only when package.json changes)║
# ║    - <install-root>/api-server/node_modules/                ║
# ║    - <install-root>/manager/node_modules/                   ║
# ║      (preserved; reinstalled only when package.json changes)║
# ╚══════════════════════════════════════════════════════════════╝

MIGRATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-instance scripts source (excludes api-server/ and minecraft-server-manager/,
# which are root-level and handled separately below).
NEW_SCRIPTS_SOURCE="$MIGRATE_SCRIPT_DIR/src/scripts"

# Root-level component sources → deployed as <install-root>/api-server/ and <install-root>/manager/
NEW_API_SERVER_SOURCE="$NEW_SCRIPTS_SOURCE/api-server"
NEW_MANAGER_SOURCE="$NEW_SCRIPTS_SOURCE/minecraft-server-manager"

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
  <path-to-scripts-dir>   Path to the deployed per-instance scripts directory.
                          Typically: <install-root>/scripts/<instance>
                          Example:   /home/mc/minecraft-server/scripts/survival

  The install root (<install-root>) is derived as two levels above this path.
  api-server/ and manager/ are updated there, not inside the instance dir.

Options:
  --y          Skip all confirmation prompts
  --no-stop    Don't stop the server before migration
  --dry-run    Show what would be done without making changes
  --help       Show this help

What gets replaced:
  - All .sh and .js files in the instance scripts dir
  - <install-root>/api-server/   (all files, node_modules preserved)
  - <install-root>/manager/      (all files, node_modules preserved)

What is NEVER touched:
  - common/variables.txt          (only new variables are appended)
  - common/downloaded_versions.json
  - interface/                    (web interface — preserved and restored)
  - update/node_modules/          (preserved; reinstalled if package.json changed)
  - api-server/node_modules/      (preserved; reinstalled if package.json changed)
  - manager/node_modules/         (preserved; reinstalled if package.json changed)
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

# Derive install root: <install-root>/scripts/<instance> → two levels up
INSTALL_ROOT="$(dirname "$(dirname "$TARGET_SCRIPTS_DIR")")"

VARS_FILE="$TARGET_SCRIPTS_DIR/common/variables.txt"
[[ ! -f "$VARS_FILE" ]] && {
  err "Not a valid scripts directory: common/variables.txt not found."
  info "Expected: $VARS_FILE"
  info "Point to the per-instance scripts dir, e.g.: /home/mc/minecraft-server/scripts/survival"
  exit 1; }

[[ ! -d "$INSTALL_ROOT/scripts" ]] && {
  err "Cannot determine install root: expected scripts/ dir at $INSTALL_ROOT"
  info "Ensure the path follows the <install-root>/scripts/<instance> layout."
  exit 1; }

[[ ! -d "$NEW_SCRIPTS_SOURCE" ]] && {
  err "New scripts source not found: $NEW_SCRIPTS_SOURCE"
  info "Run this script from the minecraft-server-setup project root."
  info "Expected: src/scripts/"
  exit 1; }

source "$VARS_FILE"

echo
echo -e "${BOLD}Minecraft Server Setup — Migration${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
info "Instance:     ${INSTANCE_NAME:-unknown}"
info "Server path:  ${SERVER_PATH:-unknown}"
info "Install root: $INSTALL_ROOT"
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
  "minecraft-server-manager/app.js"
  "minecraft-server-manager/package.json"
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

# ── What will change ──

echo -e "${BOLD}Changes to be applied${NC}"

# ── Per-instance scripts (excludes api-server/ and minecraft-server-manager/) ──
REPLACED=0; ADDED=0
while IFS= read -r f; do
  case "$f" in
    # Always preserved
    common/variables.txt|common/downloaded_versions.json) continue ;;
    # Root-level components — handled separately below
    api-server/*|minecraft-server-manager/*) continue ;;
    # node_modules — never touched
    update/node_modules/*) continue ;;
  esac
  target="$TARGET_SCRIPTS_DIR/$f"
  if [[ -f "$target" ]]; then
    diff -q "$NEW_SCRIPTS_SOURCE/$f" "$target" &>/dev/null || { info "UPDATE  $f"; REPLACED=$((REPLACED+1)); }
  else
    info "ADD     $f"; ADDED=$((ADDED+1))
  fi
done < <(cd "$NEW_SCRIPTS_SOURCE" && find . -type f | sed 's|^\./||' | sort)

# ── Per-instance npm subdir (update/) ──
declare -a NPM_SUBDIRS=()
NEEDS_ANY_NPM_INSTALL=false

for subdir in update; do
  src_pkg="$NEW_SCRIPTS_SOURCE/$subdir/package.json"
  dst_dir="$TARGET_SCRIPTS_DIR/$subdir"
  dst_pkg="$dst_dir/package.json"
  dst_modules="$dst_dir/node_modules"

  [[ ! -f "$src_pkg" ]] && continue

  has_modules=false
  needs_install=false

  if [[ -d "$dst_modules" ]]; then
    has_modules=true
    info "KEEP    ${subdir}/node_modules/  (preserved)"
  fi

  if [[ ! -d "$dst_dir" ]]; then
    needs_install=true
    info "ADD     ${subdir}/  (new — npm install will run)"
  elif ! diff -q "$src_pkg" "$dst_pkg" &>/dev/null 2>&1; then
    needs_install=true
    has_modules=false
    info "        (${subdir}/package.json changed — fresh npm install will run)"
  fi

  $needs_install && NEEDS_ANY_NPM_INSTALL=true
  NPM_SUBDIRS+=("${subdir}:${has_modules}:${needs_install}")
done

# ── Root-level components (api-server, manager) ──
# Format: "src_subdir:dst_name:has_modules:needs_install"
declare -a ROOT_NPM_SUBDIRS=()

for entry in "api-server:api-server" "minecraft-server-manager:manager"; do
  src_subdir="${entry%%:*}"; dst_name="${entry##*:}"
  src_dir="$NEW_SCRIPTS_SOURCE/$src_subdir"
  dst_dir="$INSTALL_ROOT/$dst_name"
  src_pkg="$src_dir/package.json"

  [[ ! -f "$src_pkg" ]] && continue

  has_modules=false
  needs_install=false

  # Show per-file diff for this root component
  root_replaced=0; root_added=0
  while IFS= read -r f; do
    case "$f" in node_modules/*) continue ;; esac
    target="$dst_dir/$f"
    if [[ -f "$target" ]]; then
      diff -q "$src_dir/$f" "$target" &>/dev/null || { info "UPDATE  ${dst_name}/$f"; root_replaced=$((root_replaced+1)); }
    else
      info "ADD     ${dst_name}/$f"; root_added=$((root_added+1))
    fi
  done < <(cd "$src_dir" && find . -type f | sed 's|^\./||' | sort)
  REPLACED=$((REPLACED+root_replaced)); ADDED=$((ADDED+root_added))

  if [[ -d "$dst_dir/node_modules" ]]; then
    has_modules=true
    info "KEEP    ${dst_name}/node_modules/  (preserved)"
  fi

  if [[ ! -d "$dst_dir" ]]; then
    needs_install=true
    info "ADD     ${dst_name}/  (new — npm install will run)"
  elif ! diff -q "$src_pkg" "$dst_dir/package.json" &>/dev/null 2>&1; then
    needs_install=true
    has_modules=false
    info "        (${dst_name}/package.json changed — fresh npm install will run)"
  fi

  $needs_install && NEEDS_ANY_NPM_INSTALL=true
  ROOT_NPM_SUBDIRS+=("${src_subdir}:${dst_name}:${has_modules}:${needs_install}")
done

if [[ -d "$TARGET_SCRIPTS_DIR/interface" ]]; then
  HAS_INTERFACE=true
  info "KEEP    interface/  (web interface — preserved)"
else
  HAS_INTERFACE=false
fi

# New variables
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

if [[ $REPLACED -eq 0 && $ADDED -eq 0 && ${#NEW_VARS[@]} -eq 0 && "$NEEDS_ANY_NPM_INSTALL" != true ]]; then
  log "Everything is already up to date. Nothing to do."
  exit 0
fi

echo
info "$REPLACED file(s) to update, $ADDED file(s) to add, ${#NEW_VARS[@]} variable(s) to add"
echo

# ── Confirm ──

if [[ "$SKIP_CONFIRM" != true ]]; then
  echo -e "${BOLD}This will:${NC}"
  echo "  1. Create a compressed archive backup of the scripts dir"
  $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] && echo "  2. Stop the server"
  echo "  3. Replace per-instance script files"
  echo "     Preserving: variables.txt, downloaded_versions.json, interface/,"
  echo "                 update/node_modules/, logs/"
  echo "  4. Replace root-level components:"
  echo "     $INSTALL_ROOT/api-server/  and  $INSTALL_ROOT/manager/"
  echo "     Preserving: node_modules/ in each"
  echo "  5. Add ${#NEW_VARS[@]} new variable(s) to variables.txt"
  $NEEDS_ANY_NPM_INSTALL && echo "  6. Run npm install in changed subdirs"
  $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] && echo "  7. Restart the server"
  echo
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  echo
fi

run_cmd() {
  if $DRY_RUN; then echo "[DRY-RUN] $*"; else eval "$@"; fi
}

# ── Step 1: Compressed archive backup ──

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PARENT="$(dirname "$TARGET_SCRIPTS_DIR")"
BACKUP_BASE="$(basename "$TARGET_SCRIPTS_DIR")_backup_${BACKUP_TIMESTAMP}"

echo -e "${BOLD}Step 1: Backup${NC}"
if $USE_ZSTD; then
  BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.zst"
  log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
  run_cmd "tar -C '$BACKUP_PARENT' -I 'zstd -3' -cf '$BACKUP_ARCHIVE' '$(basename "$TARGET_SCRIPTS_DIR")'"
else
  BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.gz"
  log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
  run_cmd "tar -C '$BACKUP_PARENT' -czf '$BACKUP_ARCHIVE' '$(basename "$TARGET_SCRIPTS_DIR")'"
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
  run_cmd "sudo systemctl stop '${INSTANCE_NAME}.service' 2>/dev/null || true"
  sleep 2; log "Server stopped"
else
  $SERVER_RUNNING && warn "Server running but --no-stop specified. Scripts replaced live."
fi

# ── Step 3: Replace per-instance scripts ──

echo; echo -e "${BOLD}Step 3: Replace per-instance scripts${NC}"

PRESERVE_DIR=$(mktemp -d)

# ── Save everything that must survive the wipe ──

for pf in "common/variables.txt" "common/downloaded_versions.json"; do
  [[ -f "$TARGET_SCRIPTS_DIR/$pf" ]] && {
    run_cmd "mkdir -p '$PRESERVE_DIR/$(dirname "$pf")'"
    run_cmd "cp -a '$TARGET_SCRIPTS_DIR/$pf' '$PRESERVE_DIR/$pf'"
  }
done

for logdir in "backup/logs" "logs"; do
  [[ -d "$TARGET_SCRIPTS_DIR/$logdir" ]] && {
    run_cmd "mkdir -p '$PRESERVE_DIR/$logdir'"
    run_cmd "cp -a '$TARGET_SCRIPTS_DIR/$logdir/.' '$PRESERVE_DIR/$logdir/'"
  }
done

if $HAS_INTERFACE; then
  run_cmd "mkdir -p '$PRESERVE_DIR/interface'"
  run_cmd "cp -a '$TARGET_SCRIPTS_DIR/interface/.' '$PRESERVE_DIR/interface/'"
  info "Saved: interface/"
fi

for entry in "${NPM_SUBDIRS[@]}"; do
  subdir="${entry%%:*}"; rest="${entry#*:}"
  has_modules="${rest%%:*}"; needs_install="${rest##*:}"
  if [[ "$has_modules" == true && "$needs_install" == false ]]; then
    run_cmd "mkdir -p '$PRESERVE_DIR/$subdir'"
    run_cmd "cp -a '$TARGET_SCRIPTS_DIR/$subdir/node_modules' '$PRESERVE_DIR/$subdir/node_modules'"
    info "Saved: ${subdir}/node_modules/"
  fi
done

# ── Wipe + replace (per-instance only; skip root-level source subdirs) ──
log "Removing old scripts..."
$DRY_RUN || find "$TARGET_SCRIPTS_DIR" -mindepth 1 -delete

log "Copying new scripts (excluding api-server/ and minecraft-server-manager/)..."
if ! $DRY_RUN; then
  find "$NEW_SCRIPTS_SOURCE" -mindepth 1 -maxdepth 1 \
    ! -name 'api-server' ! -name 'minecraft-server-manager' \
    -exec cp -a {} "$TARGET_SCRIPTS_DIR/" \;
fi

# ── Restore ──
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

rm -rf "$PRESERVE_DIR"
log "Per-instance scripts replaced"

# ── Step 4: Replace root-level components (api-server, manager) ──

echo; echo -e "${BOLD}Step 4: Replace root-level components${NC}"

for entry in "${ROOT_NPM_SUBDIRS[@]}"; do
  src_subdir="${entry%%:*}"; rest="${entry#*:}"
  dst_name="${rest%%:*}";    rest="${rest#*:}"
  has_modules="${rest%%:*}"; needs_install="${rest##*:}"

  src_dir="$NEW_SCRIPTS_SOURCE/$src_subdir"
  dst_dir="$INSTALL_ROOT/$dst_name"

  # Preserve node_modules if keeping them
  root_preserve=""
  if [[ "$has_modules" == true && "$needs_install" == false ]]; then
    root_preserve=$(mktemp -d)
    if ! $DRY_RUN; then
      cp -a "$dst_dir/node_modules" "$root_preserve/node_modules"
    fi
    info "Saved: ${dst_name}/node_modules/"
  fi

  log "Replacing $dst_name/..."
  if ! $DRY_RUN; then
    rm -rf "$dst_dir"
    cp -a "$src_dir" "$dst_dir"
  fi

  if [[ -n "$root_preserve" ]]; then
    if ! $DRY_RUN; then
      cp -a "$root_preserve/node_modules" "$dst_dir/node_modules"
      rm -rf "$root_preserve"
    fi
    info "Restored: ${dst_name}/node_modules/"
  fi

  log "$dst_name/ updated"
done

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

# ── Step 6: npm install in changed subdirs ──

if $NEEDS_ANY_NPM_INSTALL; then
  echo; echo -e "${BOLD}Step 6: Install npm dependencies${NC}"
  if command -v npm &>/dev/null; then
    # Per-instance subdirs (update/)
    for entry in "${NPM_SUBDIRS[@]}"; do
      subdir="${entry%%:*}"; needs_install="${entry##*:}"
      [[ "$needs_install" != true ]] && continue
      dir="$TARGET_SCRIPTS_DIR/$subdir"
      [[ -f "$dir/package.json" ]] || continue
      log "npm install --omit=dev in scripts/${subdir}/"
      run_cmd "npm install --omit=dev --prefix '$dir'"
    done
    # Root-level components (api-server/, manager/)
    for entry in "${ROOT_NPM_SUBDIRS[@]}"; do
      src_subdir="${entry%%:*}"; rest="${entry#*:}"
      dst_name="${rest%%:*}";    needs_install="${rest##*:}"
      [[ "$needs_install" != true ]] && continue
      dir="$INSTALL_ROOT/$dst_name"
      [[ -f "$dir/package.json" ]] || continue
      log "npm install --omit=dev in ${dst_name}/"
      run_cmd "npm install --omit=dev --prefix '$dir'"
    done
    log "Dependencies installed"
  else
    warn "npm not found — run manually:"
    for entry in "${NPM_SUBDIRS[@]}"; do
      subdir="${entry%%:*}"; needs_install="${entry##*:}"
      [[ "$needs_install" == true ]] && info "  npm install --omit=dev --prefix '$TARGET_SCRIPTS_DIR/$subdir'"
    done
    for entry in "${ROOT_NPM_SUBDIRS[@]}"; do
      src_subdir="${entry%%:*}"; rest="${entry#*:}"
      dst_name="${rest%%:*}";    needs_install="${rest##*:}"
      [[ "$needs_install" == true ]] && info "  npm install --omit=dev --prefix '$INSTALL_ROOT/$dst_name'"
    done
  fi
fi

# ── Step 7: Verify ──

echo; echo -e "${BOLD}Step 7: Verify${NC}"

verify_ok=true

# Per-instance files
for f in "common/server_control.sh" "common/load_variables.sh" "common/variables.txt" \
         "backup/backup.sh" "start.sh" \
         "common/rcon.js" "common/webhook.sh" "rollback.sh" "smart_restart.sh" "manage.sh" \
         "update/update-server.js" "update/update-mods.js" "update/check-updates.js" "update/package.json"; do
  [[ -f "$TARGET_SCRIPTS_DIR/$f" ]] && info "✓ $f" || { err "Missing: $f"; verify_ok=false; }
done

# Root-level components
for f in "api-server/index.js" "api-server/package.json" \
         "manager/app.js"      "manager/package.json"; do
  [[ -f "$INSTALL_ROOT/$f" ]] && info "✓ $f  (install root)" || { err "Missing: $INSTALL_ROOT/$f"; verify_ok=false; }
done

$HAS_INTERFACE && {
  [[ -d "$TARGET_SCRIPTS_DIR/interface" ]] \
    && info "✓ interface/ (preserved)" \
    || { err "interface/ was not restored — web interface will be broken"; verify_ok=false; }
}

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
  run_cmd "sudo systemctl start '${INSTANCE_NAME}.service'"
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
info "  • $INSTALL_ROOT/api-server/ — minecraft-bot HTTP API wrapper"
info "  • $INSTALL_ROOT/manager/    — Web-based server manager"
echo