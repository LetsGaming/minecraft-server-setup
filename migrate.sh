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
# ╚══════════════════════════════════════════════════════════════╝

MIGRATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_SCRIPTS_SOURCE="$MIGRATE_SCRIPT_DIR/scripts"

# ── Colors (if terminal supports it) ──
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
                          This is typically: <target>/scripts/<instance>
                          Example: /home/mc/minecraft-server/scripts/survival

Options:
  --y                Skip all confirmation prompts
  --no-stop          Don't stop the server before migration
  --dry-run          Show what would be done without making changes
  --help             Show this help

What gets replaced:
  - All .sh and .js script files (start, shutdown, backup, update, etc.)
  - New scripts are added (rcon.js, webhook.sh, rollback.sh, etc.)

What is NEVER touched:
  - common/variables.txt (only new variables are appended)
  - common/downloaded_versions.json
  - backup/logs/
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
      if [[ -z "$TARGET_SCRIPTS_DIR" ]]; then
        TARGET_SCRIPTS_DIR="$1"
      else
        err "Unexpected argument: $1"
        print_help; exit 1
      fi
      shift
      ;;
  esac
done

# ── Validate target ──

if [[ -z "$TARGET_SCRIPTS_DIR" ]]; then
  err "Missing required argument: path to scripts directory."
  echo
  print_help
  exit 1
fi

# Resolve to absolute path
TARGET_SCRIPTS_DIR="$(cd "$TARGET_SCRIPTS_DIR" 2>/dev/null && pwd)" || {
  err "Directory does not exist: $TARGET_SCRIPTS_DIR"
  exit 1
}

VARS_FILE="$TARGET_SCRIPTS_DIR/common/variables.txt"

if [[ ! -f "$VARS_FILE" ]]; then
  err "Not a valid scripts directory: common/variables.txt not found."
  info "Expected at: $VARS_FILE"
  info "Make sure you're pointing to the deployed scripts directory,"
  info "e.g.: /home/mc/minecraft-server/scripts/survival"
  exit 1
fi

# ── Validate source ──

if [[ ! -d "$NEW_SCRIPTS_SOURCE" ]]; then
  err "New scripts source not found at: $NEW_SCRIPTS_SOURCE"
  info "Run this script from the minecraft-server-setup project root."
  exit 1
fi

# ── Load existing config ──

source "$VARS_FILE"

echo
echo -e "${BOLD}Minecraft Server Setup — Migration${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
info "Instance:        ${INSTANCE_NAME:-unknown}"
info "Server path:     ${SERVER_PATH:-unknown}"
info "Scripts dir:     $TARGET_SCRIPTS_DIR"
info "Source (new):    $NEW_SCRIPTS_SOURCE"
echo

# ── Pre-migration checks ──

echo -e "${BOLD}Pre-migration checks${NC}"

# Check that new scripts source has the expected structure
REQUIRED_NEW_FILES=(
  "common/server_control.sh"
  "common/load_variables.sh"
  "common/rcon.js"
  "common/webhook.sh"
  "backup/backup.sh"
  "start.sh"
  "shutdown.sh"
)
check_ok=true
for f in "${REQUIRED_NEW_FILES[@]}"; do
  if [[ ! -f "$NEW_SCRIPTS_SOURCE/$f" ]]; then
    err "Missing in new scripts: $f"
    check_ok=false
  fi
done
if $check_ok; then
  log "New scripts source is complete"
else
  err "New scripts source is incomplete. Aborting."
  exit 1
fi

# Check server status
SERVER_RUNNING=false
if [[ -n "${INSTANCE_NAME:-}" ]]; then
  if screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then
    SERVER_RUNNING=true
    warn "Server '$INSTANCE_NAME' is currently running"
  elif systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then
    SERVER_RUNNING=true
    warn "Server '$INSTANCE_NAME' is currently running (systemd)"
  else
    log "Server is not running"
  fi
fi

# Check disk space for backup
AVAIL_MB=$(df -BM "$TARGET_SCRIPTS_DIR" | tail -1 | awk '{print $4}' | tr -d 'M')
SCRIPTS_SIZE_MB=$(du -sm "$TARGET_SCRIPTS_DIR" | cut -f1)
if (( AVAIL_MB < SCRIPTS_SIZE_MB * 2 )); then
  warn "Low disk space: ${AVAIL_MB}MB available, scripts are ${SCRIPTS_SIZE_MB}MB"
else
  log "Disk space OK (${AVAIL_MB}MB available)"
fi

echo

# ── Identify what will change ──

echo -e "${BOLD}Changes to be applied${NC}"

# Files that will be replaced
REPLACED=0
ADDED=0
for f in $(cd "$NEW_SCRIPTS_SOURCE" && find . -type f | sed 's|^\./||' | sort); do
  target="$TARGET_SCRIPTS_DIR/$f"
  # Skip files we explicitly preserve
  case "$f" in
    common/variables.txt|common/downloaded_versions.json)
      continue ;;
  esac
  if [[ -f "$target" ]]; then
    # Check if content differs
    if ! diff -q "$NEW_SCRIPTS_SOURCE/$f" "$target" &>/dev/null; then
      info "UPDATE  $f"
      REPLACED=$((REPLACED + 1))
    fi
  else
    info "ADD     $f"
    ADDED=$((ADDED + 1))
  fi
done

# Check for new variables to add
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
)

for entry in "${NEW_VAR_DEFAULTS[@]}"; do
  varname="${entry%%=*}"
  if ! grep -q "^${varname}=" "$VARS_FILE" 2>/dev/null; then
    NEW_VARS+=("$entry")
    info "ADD VAR $varname"
  fi
done

if [[ $REPLACED -eq 0 && $ADDED -eq 0 && ${#NEW_VARS[@]} -eq 0 ]]; then
  log "Everything is already up to date. Nothing to do."
  exit 0
fi

echo
info "$REPLACED file(s) to update, $ADDED file(s) to add, ${#NEW_VARS[@]} variable(s) to add"
echo

# ── Confirm ──

if [[ "$SKIP_CONFIRM" != true ]]; then
  echo -e "${BOLD}This will:${NC}"
  echo "  1. Create a backup of the current scripts directory"
  if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]]; then
    echo "  2. Stop the server"
  fi
  echo "  3. Replace script files (preserving variables.txt and downloaded_versions.json)"
  echo "  4. Add new variables with safe defaults to variables.txt"
  if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]]; then
    echo "  5. Restart the server"
  fi
  echo
  read -rp "Proceed? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo
fi

# ── Dry run gate ──

run_cmd() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

# ── Step 1: Backup current scripts ──

BACKUP_DIR="${TARGET_SCRIPTS_DIR}_backup_$(date +%Y%m%d_%H%M%S)"

echo -e "${BOLD}Step 1: Backup${NC}"
log "Backing up current scripts to: $(basename "$BACKUP_DIR")"
run_cmd "cp -a '$TARGET_SCRIPTS_DIR' '$BACKUP_DIR'"

# ── Step 2: Stop server (if running and not skipped) ──

if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]]; then
  echo
  echo -e "${BOLD}Step 2: Stop server${NC}"
  log "Stopping server '$INSTANCE_NAME'..."

  # Try graceful screen message first
  if ! $DRY_RUN; then
    if screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then
      if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$USER" screen -S "$INSTANCE_NAME" -p 0 -X stuff "/say Server is updating scripts. Restarting shortly.$(printf \\r)" 2>/dev/null || true
      else
        screen -S "$INSTANCE_NAME" -p 0 -X stuff "/say Server is updating scripts. Restarting shortly.$(printf \\r)" 2>/dev/null || true
      fi
      sleep 3
    fi
  fi

  run_cmd "sudo systemctl stop '${INSTANCE_NAME}.service' 2>/dev/null || true"
  sleep 2
  log "Server stopped"
else
  if $SERVER_RUNNING; then
    warn "Server is running but --no-stop was specified. Scripts will be replaced live."
  fi
fi

# ── Step 3: Replace scripts ──

echo
echo -e "${BOLD}Step 3: Replace scripts${NC}"

# Preserve these files by copying them out temporarily
PRESERVE_FILES=(
  "common/variables.txt"
  "common/downloaded_versions.json"
)

PRESERVE_DIR=$(mktemp -d)
for pf in "${PRESERVE_FILES[@]}"; do
  src="$TARGET_SCRIPTS_DIR/$pf"
  if [[ -f "$src" ]]; then
    pf_dir=$(dirname "$pf")
    run_cmd "mkdir -p '$PRESERVE_DIR/$pf_dir'"
    run_cmd "cp -a '$src' '$PRESERVE_DIR/$pf'"
  fi
done

# Also preserve log directories
if [[ -d "$TARGET_SCRIPTS_DIR/backup/logs" ]]; then
  run_cmd "mkdir -p '$PRESERVE_DIR/backup/logs'"
  run_cmd "cp -a '$TARGET_SCRIPTS_DIR/backup/logs/.' '$PRESERVE_DIR/backup/logs/'"
fi
if [[ -d "$TARGET_SCRIPTS_DIR/logs" ]]; then
  run_cmd "mkdir -p '$PRESERVE_DIR/logs'"
  run_cmd "cp -a '$TARGET_SCRIPTS_DIR/logs/.' '$PRESERVE_DIR/logs/'"
fi

# Clear target scripts dir (but not the dir itself)
log "Removing old scripts..."
if ! $DRY_RUN; then
  find "$TARGET_SCRIPTS_DIR" -mindepth 1 -delete
fi

# Copy new scripts
log "Copying new scripts..."
if ! $DRY_RUN; then
  cp -a "$NEW_SCRIPTS_SOURCE/." "$TARGET_SCRIPTS_DIR/"
fi

# Restore preserved files
log "Restoring preserved files..."
for pf in "${PRESERVE_FILES[@]}"; do
  preserved="$PRESERVE_DIR/$pf"
  if [[ -f "$preserved" ]]; then
    pf_dir=$(dirname "$pf")
    if ! $DRY_RUN; then
      mkdir -p "$TARGET_SCRIPTS_DIR/$pf_dir"
      cp -a "$preserved" "$TARGET_SCRIPTS_DIR/$pf"
    fi
    info "Restored: $pf"
  fi
done

# Restore logs
if [[ -d "$PRESERVE_DIR/backup/logs" ]]; then
  if ! $DRY_RUN; then
    mkdir -p "$TARGET_SCRIPTS_DIR/backup/logs"
    cp -a "$PRESERVE_DIR/backup/logs/." "$TARGET_SCRIPTS_DIR/backup/logs/"
  fi
  info "Restored: backup/logs/"
fi
if [[ -d "$PRESERVE_DIR/logs" ]]; then
  if ! $DRY_RUN; then
    mkdir -p "$TARGET_SCRIPTS_DIR/logs"
    cp -a "$PRESERVE_DIR/logs/." "$TARGET_SCRIPTS_DIR/logs/"
  fi
  info "Restored: logs/"
fi

# Clean up temp
rm -rf "$PRESERVE_DIR"

log "Scripts replaced"

# ── Step 4: Merge new variables ──

echo
echo -e "${BOLD}Step 4: Update variables.txt${NC}"

if [[ ${#NEW_VARS[@]} -gt 0 ]]; then
  if ! $DRY_RUN; then
    {
      echo ""
      echo "# ── Added by migration $(date +%Y-%m-%d) ──"
      for entry in "${NEW_VARS[@]}"; do
        echo "$entry"
      done
    } >> "$VARS_FILE"
  fi
  log "Added ${#NEW_VARS[@]} new variable(s) to variables.txt"
  for entry in "${NEW_VARS[@]}"; do
    info "  ${entry%%=*} = ${entry#*=}"
  done
else
  log "variables.txt already has all required variables"
fi

# ── Step 5: Verify ──

echo
echo -e "${BOLD}Step 5: Verify${NC}"

verify_ok=true

# Check key files exist
for f in "common/server_control.sh" "common/load_variables.sh" "common/variables.txt" "backup/backup.sh" "start.sh"; do
  if [[ -f "$TARGET_SCRIPTS_DIR/$f" ]]; then
    info "✓ $f"
  else
    err "Missing after migration: $f"
    verify_ok=false
  fi
done

# Check new files exist
for f in "common/rcon.js" "common/webhook.sh" "rollback.sh" "smart_restart.sh" "manage.sh"; do
  if [[ -f "$TARGET_SCRIPTS_DIR/$f" ]]; then
    info "✓ $f (new)"
  else
    err "Missing new file: $f"
    verify_ok=false
  fi
done

# Check variables.txt loads without error
if bash -c "source '$VARS_FILE'" 2>/dev/null; then
  info "✓ variables.txt loads correctly"
else
  err "variables.txt has syntax errors"
  verify_ok=false
fi

# Check required variables are present
for var in USER INSTANCE_NAME SERVER_PATH BACKUPS_PATH; do
  val=$(bash -c "source '$VARS_FILE' && echo \"\$$var\"" 2>/dev/null)
  if [[ -n "$val" ]]; then
    info "✓ $var = $val"
  else
    err "$var is missing or empty in variables.txt"
    verify_ok=false
  fi
done

if ! $verify_ok; then
  echo
  err "Verification failed. The backup is at:"
  info "$BACKUP_DIR"
  info "You can restore it with: rm -rf '$TARGET_SCRIPTS_DIR' && mv '$BACKUP_DIR' '$TARGET_SCRIPTS_DIR'"
  exit 1
fi

log "Verification passed"

# ── Step 6: Restart server (if it was running) ──

if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]]; then
  echo
  echo -e "${BOLD}Step 6: Restart server${NC}"
  log "Starting server '$INSTANCE_NAME'..."
  run_cmd "sudo systemctl start '${INSTANCE_NAME}.service'"

  if ! $DRY_RUN; then
    sleep 5
    if systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then
      log "Server is running"
    elif screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then
      log "Server is running (screen)"
    else
      warn "Server may still be starting. Check with: systemctl status ${INSTANCE_NAME}.service"
    fi
  fi
fi

# ── Done ──

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}${BOLD}Migration complete!${NC}"
echo
info "Backup of old scripts: $BACKUP_DIR"
info "You can remove it once you've verified everything works:"
info "  rm -rf '$BACKUP_DIR'"
echo
if [[ ${#NEW_VARS[@]} -gt 0 ]]; then
  info "New features available (edit variables.txt to enable):"
  [[ " ${NEW_VARS[*]} " == *"USE_RCON"* ]] && info "  • RCON support: set USE_RCON=\"true\" and RCON_PASSWORD"
  [[ " ${NEW_VARS[*]} " == *"WEBHOOK_URL"* ]] && info "  • Webhooks: set WEBHOOK_URL to your Discord webhook URL"
  [[ " ${NEW_VARS[*]} " == *"RESTART_ENABLED"* ]] && info "  • Scheduled restarts: set RESTART_ENABLED=\"true\""
  echo
fi
info "New scripts available:"
info "  • rollback.sh       — Roll back to pre-update backup"
info "  • smart_restart.sh  — Player-aware restart"
info "  • manage.sh         — Multi-instance management"
echo
