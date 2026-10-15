#!/bin/bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════╗
# ║  Minecraft Server Setup — Migration Script                  ║
# ║                                                             ║
# ║  Upgrades the runtime scripts of an existing server         ║
# ║  installation to the latest version. Files that are no      ║
# ║  longer part of the suite (removed or renamed upstream,     ║
# ║  e.g. after a component rewrite) are detected and deleted   ║
# ║  — a copy of everything removed stays in the pre-migration  ║
# ║  backup archive. Does NOT touch:                            ║
# ║    - World data, mods, server.jar, server.properties        ║
# ║    - Cron jobs                                              ║
# ║    - systemd units, except the migrations below             ║
# ║    - Your variables.txt values (only adds new fields)       ║
# ║    - downloaded_versions.json                               ║
# ║    - common/prune/ settings (zones) and delete journal; the ║
# ║      plans, scan cache and terrain tiles start fresh        ║
# ║    - interface/  (retired web interface — left untouched)   ║
# ║    - update/node_modules/   (preserved; reinstalled only    ║
# ║      when the dependency set changes)                       ║
# ║    - services/api-server/api-server-config.json and logs/   ║
# ║      (the wrapper itself is replaced by the release pinned  ║
# ║      in api-server-release.json when it is not current)     ║
# ║                                                             ║
# ║  Retires the bundled web interface where it finds one: the  ║
# ║  systemd unit is stopped, disabled and removed; the         ║
# ║  deployment is renamed to *.retired and left on disk,       ║
# ║  because it holds the only copy of its credentials.         ║
# ║                                                             ║
# ║  Applies the server-side migrations (src/migrations/):      ║
# ║  files the suite wrote for the server itself, namely the    ║
# ║  instance's start.sh and its systemd unit's crash-loop      ║
# ║  limits. Previewed first; never restarts the server.        ║
# ║  --list-server-migrations shows them.                       ║
# ║                                                             ║
# ║  The Minecraft instance is stopped ONLY when its folder     ║
# ║  moves to the new layout, or with --restart. Its scripts    ║
# ║  are replaced while it runs (it has none of them open);     ║
# ║  a running upgrade, prune, restore or mod change holds the  ║
# ║  operation lock, and the migration waits for none of them:  ║
# ║  it stops before changing anything. Updated services are    ║
# ║  restarted on their own.                                    ║
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
RESTART_SERVER=false
SKIP_SERVICE_RESTART=false
DRY_RUN=false
SKIP_SERVER_MIGRATIONS=false
LIST_SERVER_MIGRATIONS=false

# Defined here (not further down) so the helpers below can use it.
run_cmd() {
  $DRY_RUN && echo "[DRY-RUN] $*" || "$@"
}

print_help() {
  cat <<EOF
Usage: $0 <path-to-scripts-dir> [options]

Migrates an existing Minecraft server's runtime scripts to the latest version.

Arguments:
  <path-to-scripts-dir>   Path to the deployed scripts directory.
                          Typically: <target>/scripts/<instance>
                          Example:   /home/mc/minecraft-server/scripts/survival

Options:
  --y                    Skip all confirmation prompts
  --restart              Also restart the Minecraft server when only its scripts
                         change, so a new start.sh is used at once. Without it
                         the server keeps running: nothing it has open is
                         replaced, and a new start.sh applies at its next start
  --no-stop              Never stop the Minecraft server, not even to move its
                         instance folder to the new layout
  --no-service-restart   Don't restart the API wrapper after updating it —
                         print the command instead
  --dry-run              Show what would be done without making changes
  --no-server-migrations Skip the server-side migrations (the instance's own
                         start.sh and systemd unit)
  --list-server-migrations
                         Show each server-side migration and whether it is
                         pending, then exit; changes nothing
  --help                 Show this help

What gets replaced (per-instance scripts):
  - All .sh and .js files (start, shutdown, backup, restore, update, etc.)
  - Files no longer present in the new scripts are REMOVED (shown in the
    preview as REMOVE; a copy stays in the pre-migration backup archive)
  - Skipped entirely when nothing per-instance changed, so a services-only
    migration never touches the running instance

Server-side migrations (src/migrations/server.sh):
  Changes to files the suite wrote for the server itself, which a scripts
  update alone never reaches. Each is detected from the real files, shown in
  the preview, recorded in common/server-migrations.log, and never restarts the
  server (a changed start.sh takes effect at the next restart; the old copy is
  kept next to it).
    instance_start_script   <instance>/start.sh: lifecycle events
    unit_start_limits       systemd unit: crash-loop limits, then daemon-reload
  World data, mods, server.jar and server.properties are not touched.

The API wrapper (services/api-server/):
  Installed from the release pinned in api-server-release.json, never copied
  from this checkout (src/setup/management/install_api_server.js). When the
  installed release is not the pinned one, or the install predates releases,
  the pinned tarball is downloaded, checked against its sha256, unpacked and
  given its production dependencies in a staging folder, and only then swapped
  in. api-server-config.json and logs/ are kept. A failed download or install
  leaves the running wrapper untouched. Hosts without the wrapper get nothing.

When the Minecraft server is stopped:
  Only when the migration touches the instance — per-instance script changes,
  a per-instance npm install, or the structural instance-directory move.
  Updating only the shared services leaves the server running.

Structural migration (run once, automatically detected):
  - <install-root>/<instance>/            → <install-root>/instances/<instance>/
  - <install-root>/api-server/            → <install-root>/services/api-server/
  Updates SERVER_PATH in variables.txt and patches systemd unit files.

Retiring the bundled web interface (automatic, where one is found):
  The minecraft-server-manager panel was superseded by the minecraft-bot
  dashboard, which reaches this host through the API wrapper. Its systemd unit
  is stopped, disabled and removed — a retired service that is still enabled
  keeps a port open and comes back on the next reboot. The deployment itself is
  renamed to services/manager.retired/ rather than deleted: it holds users.json,
  and a migration that silently shreds credentials is one people stop trusting.
  The removal commands are printed.

What is NEVER touched:
  - common/variables.txt          (only new variables are appended)
  - common/downloaded_versions.json
  - common/prune/settings.json and prune-apply.journal (saved prune settings
    and protected zones, and the unfinished-delete marker; prune plans, the
    scan cache and the terrain tiles are cleared and rebuilt on demand)
  - interface/                    (retired web interface — left as found)
  - update/node_modules/          (preserved; reinstalled if deps changed)
  - services/api-server/api-server-config.json   (user config — fully preserved)
  - backup/logs/, logs/
  - common/server-migrations.log, common/migration-backups/, common/upgrade-status.ndjson,
    .locks/ (migration records, replaced units, the last job's status, operation locks)
  - World data, mods, server.jar, server.properties
  - Cron jobs, and systemd units beyond the server-side migrations above
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --y)                  SKIP_CONFIRM=true; shift ;;
    --no-stop)            SKIP_STOP=true; shift ;;
    --restart)            RESTART_SERVER=true; shift ;;
    --no-service-restart) SKIP_SERVICE_RESTART=true; shift ;;
    --dry-run)            DRY_RUN=true; shift ;;
    --no-server-migrations)    SKIP_SERVER_MIGRATIONS=true; shift ;;
    --list-server-migrations)  LIST_SERVER_MIGRATIONS=true; shift ;;
    --help|-h)            print_help; exit 0 ;;
    -*)                   err "Unknown option: $1"; print_help; exit 1 ;;
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

# BASE_DIR is the install root — derived from the scripts directory path so it
# works correctly for both old (<target>/<instance>/) and new
# (<target>/instances/<instance>/) directory structures.
# TARGET_SCRIPTS_DIR = <install-root>/scripts/<instance>
BASE_DIR="$(dirname "$(dirname "$TARGET_SCRIPTS_DIR")")"

# Validate SERVER_PATH is present (used later for structure-detection)
[[ -z "${SERVER_PATH:-}" ]] && {
  err "SERVER_PATH not set in variables.txt"
  exit 1
}

# The server-side migrations (see src/migrations/server.sh).
SM_SOURCE_ROOT="$MIGRATE_SCRIPT_DIR"
SM_INSTANCE_NAME="${INSTANCE_NAME:-}"
SM_SCRIPTS_DIR="$TARGET_SCRIPTS_DIR"
SM_INSTANCE_DIR="$SERVER_PATH"
SM_DRY_RUN=$DRY_RUN
# shellcheck source=src/migrations/server.sh
source "$MIGRATE_SCRIPT_DIR/src/migrations/server.sh"

if $LIST_SERVER_MIGRATIONS; then
  sm_list
  exit 0
fi

# The API wrapper is the one shared service. It is installed from its pinned
# release (install_api_server.js), not synced from this checkout.
API_INSTALLER="$MIGRATE_SCRIPT_DIR/src/setup/management/install_api_server.js"
API_DIR="$BASE_DIR/services/api-server"
API_SVC="$(basename "$BASE_DIR")-api-server.service"
NEEDS_API_UPDATE=false
API_UPDATE_FAILED=false
API_FROM=""; API_TO=""
SM_MIGRATIONS_OK=true

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

# ── npm helpers ──

# True when the deployed dependency set differs from the source one. Checks the
# lockfile too — a package.json-only comparison misses a lockfile bump and
# leaves node_modules out of sync with what the suite ships.
_pkg_deps_changed() {
  local src_dir="$1" dst_dir="$2"
  [[ -f "$dst_dir/package.json" ]] || return 0
  diff -q "$src_dir/package.json" "$dst_dir/package.json" &>/dev/null || return 0
  if [[ -f "$src_dir/package-lock.json" || -f "$dst_dir/package-lock.json" ]]; then
    diff -q "$src_dir/package-lock.json" "$dst_dir/package-lock.json" &>/dev/null || return 0
  fi
  return 1
}

# Install dependencies for a deployed component. Prefers `npm ci` when a
# lockfile is present (reproducible, matches the shipped tree exactly).
# $2 = "dev" includes devDependencies.
_npm_install() {
  local dir="$1" mode="${2:-prod}"
  local omit=()
  if [[ "$mode" != dev ]]; then omit=(--omit=dev); fi
  if [[ -f "$dir/package-lock.json" ]]; then
    run_cmd npm ci "${omit[@]}" --prefix "$dir"
  else
    run_cmd npm install "${omit[@]}" --prefix "$dir"
  fi
}

# ── What will change ──

echo -e "${BOLD}Changes to be applied${NC}"

# Deployment-only files carried across the wipe (the case patterns in the two
# file walks below list the same paths). Of common/prune/ only the saved
# settings, which hold the protected zones, and the delete journal, which marks
# an unfinished delete, are kept: plans, the scan cache and the terrain tiles
# are rebuilt on demand, so a migration starts them fresh.
PRESERVED_FILES=(
  "common/variables.txt"
  "common/downloaded_versions.json"
  "common/prune/settings.json"
  "common/prune/prune-apply.journal"
  # Which server migrations ran, and the last upgrade or prune job's progress
  # (the wrapper reads it back after a restart).
  "common/server-migrations.log"
  "common/upgrade-status.ndjson"
)
# Folders carried across whole: logs, the units the server migrations replaced,
# and the operation locks (a lock file swapped for a new one while something
# holds the old one would let a second operation in).
PRESERVED_DIRS=("backup/logs" "logs" "common/migration-backups" ".locks")
# Components that once lived in the instance's scripts (as git submodules) and
# no longer do: the API wrapper moved to services/, the web interface retired.
LEGACY_COMPONENTS=("api-server" "minecraft-server-manager")

# Per-instance counters
REPLACED=0; ADDED=0; STALE=0; PRUNE_CACHE_FILES=0
# The one script the running server was started with; a new one applies at its next start.
START_SCRIPT_CHANGED=false
JSON_CONFIGS=()      # "relpath:new_key_count" — per-instance config.json files
JSON_CONFIG_ADDED=0

# Per-instance npm subdirs (api-server excluded — it's root-level)
HAS_INTERFACE=false
declare -a NPM_SUBDIRS=()
NEEDS_ANY_NPM_INSTALL=false

# ── Per-instance file diff ──

while IFS= read -r f; do
  case "$f" in
    # Always-preserved files
    common/variables.txt|common/downloaded_versions.json|common/prune/settings.json|common/prune/prune-apply.journal) continue ;;
    common/server-migrations.log|common/upgrade-status.ndjson) continue ;;
    logs/*|backup/logs/*|common/migration-backups/*|.locks/*) continue ;;
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
    diff -q "$src" "$target" &>/dev/null || {
      info "UPDATE  $f"; REPLACED=$(( REPLACED + 1 ))
      [[ "$f" == "start.sh" ]] && START_SCRIPT_CHANGED=true
    }
  else
    info "ADD     $f"; ADDED=$(( ADDED + 1 ))
  fi
done < <(cd "$NEW_SCRIPTS_SOURCE" && find . -type f | sed 's|^\./||' | sort)

# ── Per-instance stale files ──
# The loop above walks the NEW source tree, so it can only ever see adds and
# updates. Files that exist in the DEPLOYMENT but were removed or renamed in
# the source (e.g. a component rewritten from .js to .ts) are invisible to it
# — walk the deployed tree too, so removals are detected, reported, and
# counted as changes. The wipe in Step 4 performs the actual deletion; the
# pre-migration backup archive keeps a copy of everything removed.
while IFS= read -r f; do
  case "$f" in
    # Deployment-only files that are preserved across the wipe
    common/variables.txt|common/downloaded_versions.json|common/prune/settings.json|common/prune/prune-apply.journal) continue ;;
    common/server-migrations.log|common/upgrade-status.ndjson) continue ;;
    interface/*) continue ;;
    update/node_modules/*) continue ;;
    logs/*|backup/logs/*|common/migration-backups/*|.locks/*) continue ;;
    */config/config.json) continue ;;
    # Legacy root-level components inside the instance dir — reported as a
    # single REMOVE per component below, not per file
    api-server/*|minecraft-server-manager/*) continue ;;
    */.git|.git|.git/*) continue ;;
    # The prune engine's plans, scan cache and terrain tiles: reported once
    # below, and not a reason on their own to replace the scripts.
    common/prune/*) PRUNE_CACHE_FILES=$(( PRUNE_CACHE_FILES + 1 )); continue ;;
  esac
  [[ -f "$NEW_SCRIPTS_SOURCE/$f" ]] && continue
  info "REMOVE  $f  (no longer part of the suite)"
  STALE=$(( STALE + 1 ))
done < <(cd "$TARGET_SCRIPTS_DIR" && find . -type f | sed 's|^\./||' | sort)
[[ $PRUNE_CACHE_FILES -gt 0 ]] && \
  info "CLEAR   common/prune/  (${PRUNE_CACHE_FILES} plan, scan cache and terrain tile file(s) — rebuilt on demand)"

# Legacy per-instance copies of the root-level components (pre-services/
# layout). Step 4 removes them; user configs inside are rescued first.
for _legacy in "${LEGACY_COMPONENTS[@]}"; do
  if [[ -d "$TARGET_SCRIPTS_DIR/$_legacy" ]]; then
    _legacy_files=$(find "$TARGET_SCRIPTS_DIR/$_legacy" -type f ! -path "*/node_modules/*" | wc -l)
    case "$_legacy" in
      api-server) _legacy_why="now root-level under services/" ;;
      *)          _legacy_why="retired, replaced by the minecraft-bot dashboard" ;;
    esac
    info "REMOVE  ${_legacy}/  (legacy per-instance copy, ${_legacy_files} file(s) — ${_legacy_why})"
    STALE=$(( STALE + 1 ))
  fi
done
# Git leaves a removed submodule's folder behind in a checkout; it is never
# copied into the instance, but say where it is so it can go.
for _legacy in "${LEGACY_COMPONENTS[@]}"; do
  if [[ -d "$NEW_SCRIPTS_SOURCE/$_legacy" ]]; then
    info "NOTE    src/scripts/$_legacy/ in this checkout is left over from the old submodule"
    info "        and no longer used. Delete it: rm -rf '$NEW_SCRIPTS_SOURCE/$_legacy'"
  fi
done

# Per-instance npm subdirs (update only; api-server is root-level)
# SC2043 fix: declare as array so the loop is extensible and ShellCheck-clean
instance_npm_dirs=(update)
for subdir in "${instance_npm_dirs[@]}"; do
  src_sub="$NEW_SCRIPTS_SOURCE/$subdir"
  dst_dir="$TARGET_SCRIPTS_DIR/$subdir"
  dst_modules="$dst_dir/node_modules"

  [[ ! -f "$src_sub/package.json" ]] && continue

  has_modules=false; needs_install=false

  if [[ -d "$dst_modules" ]]; then
    has_modules=true; info "KEEP    ${subdir}/node_modules/  (preserved)"
  fi

  if [[ ! -d "$dst_dir" ]]; then
    needs_install=true
    info "ADD     ${subdir}/  (new — npm install will run)"
  elif _pkg_deps_changed "$src_sub" "$dst_dir"; then
    needs_install=true; has_modules=false
    info "        (${subdir}/ dependencies changed — fresh npm install will run)"
  fi

  $needs_install && NEEDS_ANY_NPM_INSTALL=true
  NPM_SUBDIRS+=("${subdir}:${has_modules}:${needs_install}")
done

if [[ -d "$TARGET_SCRIPTS_DIR/interface" ]]; then
  HAS_INTERFACE=true
  info "KEEP    interface/  (web interface — preserved)"
fi

# ── API wrapper ──
# Only an install that exists is updated: the wrapper is optional. Before the
# structural move it still sits at <install-root>/api-server/.

_api_check_dir="$API_DIR"
[[ ! -d "$_api_check_dir" && -d "$BASE_DIR/api-server" ]] && _api_check_dir="$BASE_DIR/api-server"
if [[ -f "$_api_check_dir/index.js" ]]; then
  if ! command -v node &>/dev/null; then
    warn "node not found — cannot check the API wrapper against its pinned release"
  elif _api_line=$(node "$API_INSTALLER" --check --dir "$_api_check_dir" 2>&1); then
    _api_state=$(sed -n 's/.*state=\([a-z]*\).*/\1/p' <<<"$_api_line")
    API_FROM=$(sed -n 's/.*installed=\([^ ]*\).*/\1/p' <<<"$_api_line")
    API_TO=$(sed -n 's/.*pinned=\([^ ]*\).*/\1/p' <<<"$_api_line")
    case "$_api_state" in
      current)
        info "KEEP    services/api-server/  (release $API_TO, as pinned)" ;;
      outdated)
        info "UPDATE  services/api-server/  ($API_FROM → release $API_TO)"
        NEEDS_API_UPDATE=true ;;
      unmanaged)
        info "UPDATE  services/api-server/  (copy from before releases, $API_FROM → release $API_TO)"
        NEEDS_API_UPDATE=true ;;
    esac
  else
    warn "Could not check the API wrapper: $_api_line"
  fi
fi

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

TOTAL_CHANGES=$(( REPLACED + ADDED + STALE ))

# ── Structural migration detection ──
# Detect whether the install uses the old flat layout and needs directories moved.

_old_instance_dir="$BASE_DIR/$INSTANCE_NAME"
_new_instance_dir="$BASE_DIR/instances/$INSTANCE_NAME"
_old_api_dir="$BASE_DIR/api-server"
_new_api_dir="$BASE_DIR/services/api-server"
# Both places an older install may have put the retired web interface.
_old_manager_dir="$BASE_DIR/manager"
_new_manager_dir="$BASE_DIR/services/manager"
_manager_svc_name="$(basename "$BASE_DIR")-manager.service"

NEEDS_INSTANCE_MOVE=false
NEEDS_API_MOVE=false
NEEDS_MANAGER_RETIRE=false

# Instance move: SERVER_PATH still points at the old location and that dir exists
if [[ "${SERVER_PATH:-}" == "$_old_instance_dir" && -d "$_old_instance_dir" && ! -d "$_new_instance_dir" ]]; then
  NEEDS_INSTANCE_MOVE=true
  info "MOVE    instances/$INSTANCE_NAME/  (${_old_instance_dir} → ${_new_instance_dir})"
fi
# Services moves: old dir exists and new dir does not
if [[ -d "$_old_api_dir" && ! -d "$_new_api_dir" ]]; then
  NEEDS_API_MOVE=true
  info "MOVE    services/api-server/  (${_old_api_dir} → ${_new_api_dir})"
fi
# The web interface is retired rather than relocated: a unit that still exists
# is a listening, credentialed service the operator believes is gone.
if [[ -d "$_old_manager_dir" || -d "$_new_manager_dir" ]] \
   || systemctl list-unit-files "$_manager_svc_name" &>/dev/null; then
  NEEDS_MANAGER_RETIRE=true
  info "RETIRE  the bundled web interface (service + deployment)"
fi
# Server-side migrations. After an instance move the files live at the new path.
if $NEEDS_INSTANCE_MOVE; then SM_INSTANCE_DIR="$_new_instance_dir"; fi
if $SKIP_SERVER_MIGRATIONS; then
  SM_PENDING=()
else
  sm_plan
fi

NEEDS_STRUCT_MIGRATION=false
{ $NEEDS_INSTANCE_MOVE || $NEEDS_API_MOVE || $NEEDS_MANAGER_RETIRE; } && NEEDS_STRUCT_MIGRATION=true

# ── Scope: what actually has to be touched ──
# The Minecraft instance is only affected when the per-instance scripts change,
# a per-instance npm install is due, or the instance directory itself moves.
# Updating a shared service is invisible to the running java process, so a
# services-only migration must not take the world down.

NEEDS_INSTANCE_UPDATE=false
if [[ $(( REPLACED + ADDED + STALE )) -gt 0 ]] \
   || $NEEDS_ANY_NPM_INSTALL || $NEEDS_INSTANCE_MOVE; then
  NEEDS_INSTANCE_UPDATE=true
fi

# The running server never reads its scripts folder: backups, updates and the
# prune run as their own processes, and start.sh is only read when the server
# starts. So replacing the scripts does not stop it; only moving its instance
# folder does, or --restart. What must not overlap with the swap is an
# operation that runs from those scripts, which the operation lock below keeps
# out.
NEEDS_SERVER_STOP=false
if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] \
   && { $NEEDS_INSTANCE_MOVE || { $RESTART_SERVER && $NEEDS_INSTANCE_UPDATE; }; }; then
  NEEDS_SERVER_STOP=true
fi

if [[ $TOTAL_CHANGES -eq 0 && ${#NEW_VARS[@]} -eq 0 && "$NEEDS_ANY_NPM_INSTALL" != true \
   && "$NEEDS_STRUCT_MIGRATION" != true && "$NEEDS_API_UPDATE" != true \
   && ${#SM_PENDING[@]} -eq 0 ]]; then
  log "Everything is already up to date. Nothing to do."
  exit 0
fi

echo
SUMMARY="$REPLACED file(s) to update, $ADDED file(s) to add, ${#NEW_VARS[@]} variable(s) to add"
[[ $STALE -gt 0 ]] && \
  SUMMARY="$SUMMARY, $STALE stale file(s) to remove"
$NEEDS_API_UPDATE && SUMMARY="$SUMMARY, API wrapper to release $API_TO" || true
[[ $JSON_CONFIG_ADDED -gt 0 ]] && \
  SUMMARY="$SUMMARY, $JSON_CONFIG_ADDED config key(s) to merge"
"$NEEDS_INSTANCE_MOVE" && SUMMARY="$SUMMARY, instance dir to relocate" || true
[[ ${#SM_PENDING[@]} -gt 0 ]] && SUMMARY="$SUMMARY, ${#SM_PENDING[@]} server migration(s)" || true
info "$SUMMARY"
echo

# ── Confirm ──

if [[ "$SKIP_CONFIRM" != true ]]; then
  echo -e "${BOLD}This will:${NC}"
  echo "  1. Create a compressed archive backup of the scripts dir"
  if $NEEDS_SERVER_STOP; then
    echo "  2. Stop the Minecraft server"
  elif $SERVER_RUNNING; then
    echo "  2. Leave the Minecraft server running (nothing it has open is replaced)"
    $START_SCRIPT_CHANGED && echo "     start.sh changes: the new one applies at its next start (--restart to apply now)"
  fi
  if [[ "$NEEDS_STRUCT_MIGRATION" == true ]]; then
    echo "  3. Structural directory migration:"
    $NEEDS_INSTANCE_MOVE && echo "       mv  $BASE_DIR/$INSTANCE_NAME  →  $BASE_DIR/instances/$INSTANCE_NAME"
    $NEEDS_API_MOVE      && echo "       mv  $BASE_DIR/api-server  →  $BASE_DIR/services/api-server"
    $NEEDS_MANAGER_RETIRE && echo "       retire the bundled web interface (stop/disable/remove its unit,"
    $NEEDS_MANAGER_RETIRE && echo "              rename its deployment to *.retired — nothing is deleted)"
    $NEEDS_INSTANCE_MOVE && echo "     Updates SERVER_PATH in variables.txt and patches systemd unit files"
  fi
  if $NEEDS_INSTANCE_UPDATE; then
    echo "  4. Replace per-instance script files"
    echo "     Preserving: variables.txt, downloaded_versions.json, interface/,"
    echo "                 update/node_modules/, logs/, prune settings and journal,"
    echo "                 migration records and backups, upgrade status, operation locks"
    echo "     Clearing:   prune plans, scan cache and terrain tiles (rebuilt on demand)"
    [[ $STALE -gt 0 ]] && \
      echo "     Removing $STALE stale per-instance file(s)/component(s)"
    if [[ ${#JSON_CONFIGS[@]} -gt 0 ]]; then
      for entry in "${JSON_CONFIGS[@]}"; do
        f="${entry%%:*}"; nk="${entry##*:}"
        [[ "$nk" -gt 0 ]] \
          && echo "     Merging (not replacing): $f  ($nk new key(s))" \
          || echo "     Keeping unchanged: $f"
      done
    fi
  else
    echo "  4. Skip per-instance scripts (nothing changed — left untouched)"
  fi
  if $NEEDS_API_UPDATE; then
    echo "  5. Install API wrapper release $API_TO in $API_DIR"
    echo "     (downloaded and checked first; keeps api-server-config.json and logs/)"
  fi
  [[ $STALE -gt 0 ]] && \
    echo "     (all removed files remain available in the backup archive)"
  echo "  6. Add ${#NEW_VARS[@]} new variable(s) to variables.txt"
  if [[ ${#SM_PENDING[@]} -gt 0 ]]; then
    echo " 6b. Server migrations (the server is not restarted):"
    for _id in "${SM_PENDING[@]}"; do echo "       - $("sm_${_id}_describe")"; done
  fi
  $NEEDS_ANY_NPM_INSTALL && echo "  7. Run npm install in changed per-instance subdirs"
  $NEEDS_SERVER_STOP && echo "  9. Restart the Minecraft server"
  if $NEEDS_API_UPDATE && [[ "$SKIP_SERVICE_RESTART" != true ]]; then
    echo " 9b. Restart $API_SVC"
  fi
  echo
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  echo
fi

# ── Operation lock ──
# The scripts are swapped under a running server, so nothing may be running
# from them meanwhile: an upgrade or prune job, a restore, a rollback, a mod
# change. They all take this lock; take it too, and stop before changing
# anything when one of them holds it. Taken in every place a script may look
# for it (utils.sh: INSTANCE_LOCK_DIR, else the runtime dir, else .locks).
acquire_migration_locks() {
  local dirs=() dir lock fd
  [[ -n "${INSTANCE_LOCK_DIR:-}" ]] && dirs+=("$INSTANCE_LOCK_DIR")
  [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR/minecraft" ]] && dirs+=("$XDG_RUNTIME_DIR/minecraft")
  dirs+=("$TARGET_SCRIPTS_DIR/.locks")
  command -v flock &>/dev/null || { warn "flock not found — cannot check for a running operation"; return 0; }
  for dir in "${dirs[@]}"; do
    ( umask 077; mkdir -p "$dir" ) || continue
    lock="$dir/operation_${INSTANCE_NAME}.lock"
    exec {fd}> "$lock" || continue
    if ! flock -n "$fd"; then
      err "Another operation ($(cat "$lock.kind" 2>/dev/null || echo unknown)) is running for '$INSTANCE_NAME'."
      info "Run the migration again once it has finished. Nothing was changed."
      exit 1
    fi
  done
}
if $NEEDS_INSTANCE_UPDATE && ! $DRY_RUN; then
  acquire_migration_locks
fi

# ── Step 1: Compressed archive backup ──

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PARENT="$(dirname "$TARGET_SCRIPTS_DIR")"
BACKUP_BASE="$(basename "$TARGET_SCRIPTS_DIR")_backup_${BACKUP_TIMESTAMP}"

echo -e "${BOLD}Step 1: Backup${NC}"
if $USE_ZSTD; then
  BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.zst"
  log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
  # umask 077 (S-029): the archive holds common/variables.txt and its secrets.
  ( umask 077; run_cmd tar -C "$BACKUP_PARENT" -I 'zstd -3' -cf "$BACKUP_ARCHIVE" "$(basename "$TARGET_SCRIPTS_DIR")" )
else
  BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.gz"
  log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
  ( umask 077; run_cmd tar -C "$BACKUP_PARENT" -czf "$BACKUP_ARCHIVE" "$(basename "$TARGET_SCRIPTS_DIR")" )
fi
[[ -f "$BACKUP_ARCHIVE" ]] && info "Archive size: $(du -sk "$BACKUP_ARCHIVE" | cut -f1)KB"

# ── Recovery trap (S-019) ──
# From here on a failure must not leave the server down or its scripts half
# replaced. On any exit before the end, the scripts folder comes back from the
# archive above if this run touched it, and the server is started again if
# this run stopped it.
_MIGRATE_DONE=false
_MIGRATE_STOPPED_SERVER=false
_MIGRATE_SCRIPTS_TOUCHED=false
_migrate_recover() {
  local rc=$?
  $_MIGRATE_DONE && return
  $DRY_RUN && return
  echo
  err "Migration stopped before it finished (exit $rc). Undoing what it changed..."
  [[ -n "${STAGING_SCRIPTS_DIR:-}" ]] && rm -rf -- "$STAGING_SCRIPTS_DIR"
  [[ -n "${PRESERVE_DIR:-}" ]] && rm -rf -- "$PRESERVE_DIR"
  # A swap interrupted between its two renames: the old tree is still whole.
  if [[ ! -e "$TARGET_SCRIPTS_DIR" && -d "${TARGET_SCRIPTS_DIR%/}.old.$$" ]]; then
    mv -- "${TARGET_SCRIPTS_DIR%/}.old.$$" "$TARGET_SCRIPTS_DIR"
  fi
  if $_MIGRATE_SCRIPTS_TOUCHED && [[ -f "$BACKUP_ARCHIVE" ]]; then
    local restore_dir
    restore_dir="${TARGET_SCRIPTS_DIR%/}.restore.$$"
    rm -rf -- "$restore_dir"
    mkdir -p -- "$restore_dir"
    if tar -C "$restore_dir" -xf "$BACKUP_ARCHIVE" \
      && [[ -d "$restore_dir/$(basename "$TARGET_SCRIPTS_DIR")" ]]; then
      rm -rf -- "${TARGET_SCRIPTS_DIR:?}"
      mv -- "$restore_dir/$(basename "$TARGET_SCRIPTS_DIR")" "$TARGET_SCRIPTS_DIR"
      rm -rf -- "$restore_dir"
      log "Scripts restored from $(basename "$BACKUP_ARCHIVE")"
    else
      rm -rf -- "$restore_dir"
      err "Could not restore the scripts. Do it by hand:"
      info "  rm -rf '$TARGET_SCRIPTS_DIR'"
      info "  tar -C '$(dirname "$TARGET_SCRIPTS_DIR")' -xf '$BACKUP_ARCHIVE'"
    fi
  fi
  if $_MIGRATE_STOPPED_SERVER; then
    log "Starting '$INSTANCE_NAME' again..."
    sudo systemctl start "${INSTANCE_NAME}.service" 2>/dev/null \
      || warn "Could not start it: sudo systemctl start ${INSTANCE_NAME}.service"
  fi
}
trap _migrate_recover EXIT

# ── Step 2: Stop server ──

if $NEEDS_SERVER_STOP; then
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
  _MIGRATE_STOPPED_SERVER=true
  run_cmd sudo systemctl stop "${INSTANCE_NAME}.service" 2>/dev/null || true
  sleep 2; log "Server stopped"
elif $SERVER_RUNNING && [[ "$SKIP_STOP" == true ]]; then
  echo; echo -e "${BOLD}Step 2: Stop server${NC}"
  warn "Server running but --no-stop specified. Files replaced live."
elif $SERVER_RUNNING; then
  echo; echo -e "${BOLD}Step 2: Stop server${NC}"
  log "Leaving '$INSTANCE_NAME' running — nothing it has open is replaced"
fi

# ── Step 3: Structural directory migration ──
# Moves directories to the new layout if this is an old-format install.
# Safe to skip (idempotent) when the new structure is already in place.

if [[ "$NEEDS_STRUCT_MIGRATION" == true ]]; then
  echo; echo -e "${BOLD}Step 3: Structural directory migration${NC}"

  # ── 3a: Instance dir: BASE_DIR/<instance>  →  BASE_DIR/instances/<instance>
  if $NEEDS_INSTANCE_MOVE; then
    log "Moving instance dir to instances/$INSTANCE_NAME/"
    run_cmd mkdir -p "$BASE_DIR/instances"
    run_cmd mv "$_old_instance_dir" "$_new_instance_dir"
    info "Moved: $_old_instance_dir → $_new_instance_dir"

    # Update SERVER_PATH in variables.txt
    if ! $DRY_RUN; then
      sed -i "s|SERVER_PATH=\"${_old_instance_dir}\"|SERVER_PATH=\"${_new_instance_dir}\"|" "$VARS_FILE"
    else
      echo "[DRY-RUN] sed -i SERVER_PATH in $VARS_FILE"
    fi
    info "Updated SERVER_PATH in variables.txt"

    # Patch the MC instance systemd service file (WorkingDirectory + ExecStart)
    _svc_file="/etc/systemd/system/${INSTANCE_NAME}.service"
    if [[ -f "$_svc_file" ]]; then
      if ! $DRY_RUN; then
        sudo sed -i "s|${_old_instance_dir}|${_new_instance_dir}|g" "$_svc_file"
        sudo systemctl daemon-reload
      else
        echo "[DRY-RUN] sudo sed -i paths in $_svc_file + daemon-reload"
      fi
      info "Patched: $_svc_file"
    fi

    # Patch api-server-config.json serverPath entries if present
    # (scriptsDir lives in BASE_DIR/scripts/ and does not change)
    for _cfg_dir in "$_new_api_dir" "$_old_api_dir"; do
      _api_cfg="$_cfg_dir/api-server-config.json"
      if [[ -f "$_api_cfg" ]]; then
        if ! $DRY_RUN; then
          # Use node to do a clean JSON edit — avoids broken JSON from sed on paths
          node -e "
            const fs = require('fs');
            const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
            const oldP = process.argv[2], newP = process.argv[3];
            for (const inst of Object.values(cfg.instances || {})) {
              if (inst.serverPath === oldP) inst.serverPath = newP;
            }
            fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
          " "$_api_cfg" "$_old_instance_dir" "$_new_instance_dir" 2>/dev/null || \
            warn "Could not auto-update serverPath in $_api_cfg — update manually"
        else
          echo "[DRY-RUN] node: update serverPath in $_api_cfg"
        fi
        info "Updated serverPath in $(basename "$_cfg_dir")/api-server-config.json"
        break
      fi
    done
  fi

  # ── 3b: api-server: BASE_DIR/api-server  →  BASE_DIR/services/api-server
  if $NEEDS_API_MOVE; then
    log "Moving api-server to services/api-server/"
    run_cmd mkdir -p "$BASE_DIR/services"
    run_cmd mv "$_old_api_dir" "$_new_api_dir"
    info "Moved: $_old_api_dir → $_new_api_dir"

    # Patch api-server systemd service file
    _api_svc_name="$(basename "$BASE_DIR")-api-server.service"
    _api_svc_file="/etc/systemd/system/$_api_svc_name"
    if [[ -f "$_api_svc_file" ]]; then
      if ! $DRY_RUN; then
        sudo sed -i "s|${_old_api_dir}|${_new_api_dir}|g" "$_api_svc_file"
        sudo systemctl daemon-reload
      else
        echo "[DRY-RUN] sudo sed -i paths in $_api_svc_file + daemon-reload"
      fi
      info "Patched: $_api_svc_file"
    fi
  fi

  # ── 3d: retire the bundled web interface
  #
  # It was superseded by the minecraft-bot dashboard, which reaches this host
  # through the API wrapper. Two halves, treated differently on purpose:
  #
  #   The systemd unit is removed automatically. A retired service that is
  #   still enabled keeps a port open and a credential file live on a host the
  #   operator believes is clean, and it comes back on the next reboot. That is
  #   the part that must not be left to a checklist.
  #
  #   The deployment directory is NOT deleted. It holds users.json — the only
  #   copy of credentials someone may still want to look at — and a migration
  #   script that silently shreds credentials is a migration script people stop
  #   trusting. It is renamed out of the way and the removal command printed.
  if $NEEDS_MANAGER_RETIRE; then
    log "Retiring the bundled web interface"

    _mgr_svc_file="/etc/systemd/system/$_manager_svc_name"
    if systemctl list-unit-files "$_manager_svc_name" &>/dev/null || [[ -f "$_mgr_svc_file" ]]; then
      if ! $DRY_RUN; then
        sudo systemctl stop    "$_manager_svc_name" 2>/dev/null || true
        sudo systemctl disable "$_manager_svc_name" 2>/dev/null || true
        sudo rm -f "$_mgr_svc_file"
        sudo systemctl daemon-reload
      else
        echo "[DRY-RUN] sudo systemctl stop/disable $_manager_svc_name"
        echo "[DRY-RUN] sudo rm -f $_mgr_svc_file + daemon-reload"
      fi
      info "Stopped, disabled and removed: $_manager_svc_name"
    fi

    for _mgr_dir in "$_new_manager_dir" "$_old_manager_dir"; do
      [[ -d "$_mgr_dir" ]] || continue
      _retired_dir="${_mgr_dir}.retired"
      run_cmd mv "$_mgr_dir" "$_retired_dir"
      info "Moved aside: $_mgr_dir → $_retired_dir"
      warn "The retired deployment still holds credentials (users.json, .env)."
      warn "Once you no longer need them:"
      warn "  sudo shred -u \"$_retired_dir\"/src/config/users.json 2>/dev/null"
      warn "  sudo rm -rf \"$_retired_dir\""
    done

    info "Its features now live in the minecraft-bot dashboard — see"
    info "docs/retiring-web-interface.md"
  fi

  # Re-source variables.txt so the rest of the script sees the updated SERVER_PATH
  $DRY_RUN || source "$VARS_FILE"
  log "Structural migration complete"
else
  echo; echo -e "${BOLD}Step 3: Structural directory migration${NC}"
  log "Already using new directory layout — nothing to move"
fi

# ── Step 4: Replace per-instance scripts ──
# Wrapped in a function so the whole wipe-and-restore can be skipped when the
# instance has no changes. Deleting and re-copying identical files under a
# running server buys nothing and opens a window where a cron job or the
# running control scripts find their files missing.

replace_instance_scripts() {
echo; echo -e "${BOLD}Step 4: Replace per-instance scripts${NC}"

# Next to the scripts, not in /tmp: it holds variables.txt (S-019).
PRESERVE_DIR="${TARGET_SCRIPTS_DIR%/}.preserve.$$"
rm -rf -- "$PRESERVE_DIR"
( umask 077; mkdir -p -- "$PRESERVE_DIR" )

# Save files that must survive the wipe
for pf in "${PRESERVED_FILES[@]}"; do
  [[ -f "$TARGET_SCRIPTS_DIR/$pf" ]] && {
    run_cmd mkdir -p "$PRESERVE_DIR/$(dirname "$pf")"
    run_cmd cp -a "$TARGET_SCRIPTS_DIR/$pf" "$PRESERVE_DIR/$pf"
  }
done

for logdir in "${PRESERVED_DIRS[@]}"; do
  [[ -d "$TARGET_SCRIPTS_DIR/$logdir" ]] && {
    # The folder itself, not only its contents: .locks/ and migration-backups/ are owner only.
    run_cmd mkdir -p "$PRESERVE_DIR/$(dirname "$logdir")"
    run_cmd cp -a "$TARGET_SCRIPTS_DIR/$logdir" "$PRESERVE_DIR/$(dirname "$logdir")/"
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

# Legacy per-instance components: before the wipe destroys them, rescue any
# user-generated config into the root-level service location (if it exists
# and has none yet). The backup archive keeps the full legacy tree either way.
_legacy_api="$TARGET_SCRIPTS_DIR/api-server"
if [[ -f "$_legacy_api/api-server-config.json" ]]; then
  _root_api="$BASE_DIR/services/api-server"
  [[ ! -d "$_root_api" && -d "$BASE_DIR/api-server" ]] && _root_api="$BASE_DIR/api-server"
  if [[ -d "$_root_api" && ! -f "$_root_api/api-server-config.json" ]]; then
    run_cmd cp -a "$_legacy_api/api-server-config.json" "$_root_api/api-server-config.json"
    log "Rescued legacy api-server-config.json → $_root_api/"
  else
    warn "Legacy per-instance api-server/ has a config — it will be removed."
    info "A copy remains in the backup archive; the root-level service keeps its own config."
  fi
fi
# A pre-services install may still have a per-instance copy of the retired web
# interface under scripts/. It used to have its config rescued into the
# root-level deployment; there is no longer a live deployment to rescue it into.
# Step 1's archive holds the whole tree, so nothing is lost — say where.
_legacy_mgr="$TARGET_SCRIPTS_DIR/minecraft-server-manager"
if [[ -d "$_legacy_mgr" ]]; then
  warn "Legacy per-instance web interface found — it will be removed."
  info "The web interface was retired; its config (including users.json) is in"
  info "the pre-migration backup archive if you still need it."
fi

# Build the new tree next to the old one and swap it in at the end (S-019):
# deleting first and copying after left an empty or partial scripts folder
# whenever the copy failed (a full disk), with the server already stopped.
STAGING_SCRIPTS_DIR="${TARGET_SCRIPTS_DIR%/}.migrate-staging.$$"
log "Copying new per-instance scripts..."
$DRY_RUN || { rm -rf -- "$STAGING_SCRIPTS_DIR"; mkdir -p -- "$STAGING_SCRIPTS_DIR"; cp -a "$NEW_SCRIPTS_SOURCE/." "$STAGING_SCRIPTS_DIR/"; }

# A checkout from the submodule days can still hold src/scripts/api-server/ or
# src/scripts/minecraft-server-manager/: git leaves a removed submodule's folder
# behind as untracked files. They were copied along above and do not belong in
# the instance's scripts; left in, every later run reported them again.
for _legacy in "${LEGACY_COMPONENTS[@]}"; do
  if [[ -d "$STAGING_SCRIPTS_DIR/$_legacy" ]]; then
    # :? aborts if STAGING_SCRIPTS_DIR is somehow empty, preventing rm -rf /<name>
    $DRY_RUN || rm -rf "${STAGING_SCRIPTS_DIR:?}/$_legacy"
  fi
done

# Restore preserved files
log "Restoring preserved files..."

for pf in "${PRESERVED_FILES[@]}"; do
  [[ -f "$PRESERVE_DIR/$pf" ]] && {
    $DRY_RUN || {
      # common/prune/ holds zones and the delete journal: owner only, as the engine creates it.
      ( umask 077; mkdir -p "$STAGING_SCRIPTS_DIR/$(dirname "$pf")" )
      cp -a "$PRESERVE_DIR/$pf" "$STAGING_SCRIPTS_DIR/$pf"
    }
    info "Restored: $pf"
  }
done

for logdir in "${PRESERVED_DIRS[@]}"; do
  [[ -d "$PRESERVE_DIR/$logdir" ]] && {
    $DRY_RUN || {
      mkdir -p "$STAGING_SCRIPTS_DIR/$logdir"
      cp -a "$PRESERVE_DIR/$logdir/." "$STAGING_SCRIPTS_DIR/$logdir/"
      chmod --reference="$PRESERVE_DIR/$logdir" "$STAGING_SCRIPTS_DIR/$logdir"
    }
    info "Restored: $logdir/"
  }
done

if [[ -d "$PRESERVE_DIR/interface" ]]; then
  $DRY_RUN || { mkdir -p "$STAGING_SCRIPTS_DIR/interface"; cp -a "$PRESERVE_DIR/interface/." "$STAGING_SCRIPTS_DIR/interface/"; }
  info "Restored: interface/"
fi

for entry in "${NPM_SUBDIRS[@]}"; do
  subdir="${entry%%:*}"; rest="${entry#*:}"
  has_modules="${rest%%:*}"; needs_install="${rest##*:}"
  if [[ "$has_modules" == true && "$needs_install" == false ]] && [[ -d "$PRESERVE_DIR/$subdir/node_modules" ]]; then
    $DRY_RUN || { mkdir -p "$STAGING_SCRIPTS_DIR/$subdir"; cp -a "$PRESERVE_DIR/$subdir/node_modules" "$STAGING_SCRIPTS_DIR/$subdir/node_modules"; }
    info "Restored: ${subdir}/node_modules/"
  fi
done

for entry in "${JSON_CONFIGS[@]:-}"; do
  [[ -z "$entry" ]] && continue
  f="${entry%%:*}"; nk="${entry##*:}"
  preserved="$PRESERVE_DIR/$f"
  deployed="$STAGING_SCRIPTS_DIR/$f"
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

# The swap: two renames, and the old tree goes only once the new one is in.
if ! $DRY_RUN; then
  _MIGRATE_SCRIPTS_TOUCHED=true
  mv -- "$TARGET_SCRIPTS_DIR" "${TARGET_SCRIPTS_DIR%/}.old.$$"
  mv -- "$STAGING_SCRIPTS_DIR" "$TARGET_SCRIPTS_DIR"
  rm -rf -- "${TARGET_SCRIPTS_DIR%/}.old.$$"
fi
rm -rf -- "$PRESERVE_DIR"
log "Per-instance scripts replaced"
}

if $NEEDS_INSTANCE_UPDATE; then
  replace_instance_scripts
else
  echo; echo -e "${BOLD}Step 4: Replace per-instance scripts${NC}"
  log "No per-instance changes — scripts left untouched"
fi

# ── Step 5: API wrapper ──
# install_api_server.js stages and checks the release before it touches the
# install, so a failure here leaves the running wrapper as it was.

if $NEEDS_API_UPDATE; then
  echo; echo -e "${BOLD}Step 5: API wrapper${NC}"
  _api_args=(--dir "$API_DIR")
  $DRY_RUN && _api_args+=(--dry-run)
  if node "$API_INSTALLER" "${_api_args[@]}"; then
    log "API wrapper is on release $API_TO"
  else
    err "Installing API wrapper release $API_TO failed — the previous install is unchanged"
    API_UPDATE_FAILED=true
  fi
fi

# ── Step 6: Merge new variables ──

echo; echo -e "${BOLD}Step 6: Update variables.txt${NC}"

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

# ── Step 6b: Server-side migrations ──
# Files the suite wrote for the server itself. None of them restarts it.

if [[ ${#SM_PENDING[@]} -gt 0 ]]; then
  echo; echo -e "${BOLD}Step 6b: Server migrations${NC}"
  # Variables may have moved with the instance; point the migrations at the final path.
  SM_INSTANCE_DIR="$SERVER_PATH"
  SM_DRY_RUN=$DRY_RUN
  SM_MIGRATIONS_OK=true
  sm_apply || SM_MIGRATIONS_OK=false
fi

# ── Step 7: npm install in changed per-instance subdirs ──

if $NEEDS_ANY_NPM_INSTALL; then
  echo; echo -e "${BOLD}Step 7: Install npm dependencies${NC}"
  if command -v npm &>/dev/null; then
    for entry in "${NPM_SUBDIRS[@]}"; do
      subdir="${entry%%:*}"; needs_install="${entry##*:}"
      [[ "$needs_install" != true ]] && continue
      dir="$TARGET_SCRIPTS_DIR/$subdir"
      [[ -f "$dir/package.json" ]] || continue
      log "npm install --omit=dev in ${subdir}/"
      _npm_install "$dir"
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

# ── Step 8: Verify ──

echo; echo -e "${BOLD}Step 8: Verify${NC}"

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

# The wrapper runs from dist/; an install without it will not start.
if [[ -f "$API_DIR/index.js" ]] && ! $DRY_RUN; then
  if [[ -f "$API_DIR/dist/index.js" ]]; then
    info "✓ services/api-server/dist/index.js present"
  else
    err "services/api-server/dist/index.js is missing — the API wrapper will not start"
    verify_ok=false
  fi
fi

bash -c "source '$VARS_FILE'" 2>/dev/null \
  && info "✓ variables.txt loads correctly" \
  || { err "variables.txt has syntax errors"; verify_ok=false; }

for var in USER INSTANCE_NAME SERVER_PATH BACKUPS_PATH; do
  val=$(bash -c "source '$VARS_FILE' && echo \"\$$var\"" 2>/dev/null)
  [[ -n "$val" ]] && info "✓ $var = $val" || { err "$var missing in variables.txt"; verify_ok=false; }
done

if ! $verify_ok; then
  echo; err "Verification failed; the previous scripts are put back."
  exit 1
fi
log "Verification passed"
_MIGRATE_DONE=true

# ── Step 9: Restart the Minecraft server ──
# Only when it was stopped by this migration.

if $NEEDS_SERVER_STOP; then
  echo; echo -e "${BOLD}Step 9: Restart server${NC}"
  log "Starting '$INSTANCE_NAME'..."
  run_cmd sudo systemctl start "${INSTANCE_NAME}.service"
  if ! $DRY_RUN; then
    sleep 5
    if systemctl is-active "${INSTANCE_NAME}.service" &>/dev/null; then log "Server is running"
    elif screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"; then log "Server is running (screen)"
    else warn "Server may still be starting. Check: systemctl status ${INSTANCE_NAME}.service"; fi
  fi
fi

# ── Step 9b: Restart the API wrapper ──
# Only after a successful update. The Minecraft instance is unaffected.

RESTART_HINTS=()
if $NEEDS_API_UPDATE && ! $API_UPDATE_FAILED; then
  echo; echo -e "${BOLD}Step 9b: Restart the API wrapper${NC}"
  if [[ "$SKIP_SERVICE_RESTART" == true ]]; then
    info "Skipped (--no-service-restart): $API_SVC"
    RESTART_HINTS+=("$API_SVC")
  elif [[ -f "/etc/systemd/system/$API_SVC" ]]; then
    log "Restarting $API_SVC"
    run_cmd sudo systemctl restart "$API_SVC"
    if ! $DRY_RUN; then
      sleep 2
      systemctl is-active "$API_SVC" &>/dev/null \
        && info "  $API_SVC is active" \
        || warn "  $API_SVC did not come up — check: systemctl status $API_SVC"
    fi
  else
    warn "No systemd unit $API_SVC — restart services/api-server manually"
    RESTART_HINTS+=("$API_SVC")
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
if [[ ${#SM_FAILED[@]} -gt 0 ]]; then
  err "Server migration(s) failed: ${SM_FAILED[*]}. They run again on the next migration."
  echo
fi
if [[ ${#SM_MANUAL[@]} -gt 0 ]]; then
  warn "Server migration(s) need a manual step (printed above): ${SM_MANUAL[*]}"
  echo
fi
if $SM_NEEDS_RESTART; then
  info "The instance's start.sh was updated. It takes effect the next time '$INSTANCE_NAME' starts."
  echo
fi
if $API_UPDATE_FAILED; then
  err "The API wrapper was not updated — it still runs ${API_FROM:-its previous release}."
  info "Check the output of Step 5, then run migrate.sh again."
  echo
fi
if [[ ${#RESTART_HINTS[@]} -gt 0 ]]; then
  warn "These services were updated but not restarted:"
  for _svc in "${RESTART_HINTS[@]}"; do info "  sudo systemctl restart $_svc"; done
  echo
fi
if $SERVER_RUNNING && ! $NEEDS_SERVER_STOP; then
  info "Minecraft instance '$INSTANCE_NAME' was left running — nothing it has open changed."
  if $START_SCRIPT_CHANGED; then
    info "start.sh changed: it applies at the server's next start, or run again with --restart."
  fi
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
info "  • services/api-server/      — minecraft-bot HTTP API wrapper"
echo
