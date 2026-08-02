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
# ║    - Systemd services, cron jobs                            ║
# ║    - Your variables.txt values (only adds new fields)       ║
# ║    - downloaded_versions.json                               ║
# ║    - interface/  (retired web interface — left untouched)   ║
# ║    - update/node_modules/   (preserved; reinstalled only    ║
# ║      when the dependency set changes)                       ║
# ║    - services/api-server/node_modules/  (same)              ║
# ║    - services/*/dist/  (build output — rebuilt, not         ║
# ║      deleted; the previous build survives a failed build)   ║
# ║    - services/api-server/api-server-config.json  (untouched)║
# ║                                                             ║
# ║  Retires the bundled web interface where it finds one: the  ║
# ║  systemd unit is stopped, disabled and removed; the         ║
# ║  deployment is renamed to *.retired and left on disk,       ║
# ║  because it holds the only copy of its credentials.         ║
# ║                                                             ║
# ║  The Minecraft instance is stopped ONLY when the migration  ║
# ║  actually touches it. A services-only update leaves the     ║
# ║  server running and restarts just the affected units.       ║
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
SKIP_SERVICE_RESTART=false
DRY_RUN=false

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
  --no-stop              Never stop the Minecraft server, even when the
                         per-instance scripts change
  --no-service-restart   Don't restart updated shared services (api-server,
                         manager) — print the commands instead
  --dry-run              Show what would be done without making changes
  --help                 Show this help

What gets replaced (per-instance scripts):
  - All .sh and .js files (start, shutdown, backup, restore, update, etc.)
  - Files no longer present in the new scripts are REMOVED (shown in the
    preview as REMOVE; a copy stays in the pre-migration backup archive)
  - Skipped entirely when nothing per-instance changed, so a services-only
    migration never touches the running instance

What gets updated (shared services):
  - services/api-server/   at <install-root>/services/api-server/
  Fully replaced: files removed upstream are deleted, and a changed
  dependency set (package.json / package-lock.json) triggers a fresh install
  instead of restoring the old node_modules/

Build output (services/*/dist/):
  Services whose package.json declares a "build" script are compiled, not
  copied. dist/ is therefore NEVER treated as stale: the existing build is
  carried across the replace step and regenerated with \`npm run build\`
  whenever the service's sources changed or dist/ is missing. devDependencies
  are installed for the build and pruned again afterwards. If the build fails,
  the previous dist/ stays in place and the failure is reported.

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
  - interface/                    (retired web interface — left as found)
  - update/node_modules/          (preserved; reinstalled if deps changed)
  - services/api-server/node_modules/            (same)
  - services/api-server/api-server-config.json   (user config — fully preserved)
  - backup/logs/, logs/
  - World data, mods, server.jar, server.properties
  - Systemd services, cron jobs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --y)                  SKIP_CONFIRM=true; shift ;;
    --no-stop)            SKIP_STOP=true; shift ;;
    --no-service-restart) SKIP_SERVICE_RESTART=true; shift ;;
    --dry-run)            DRY_RUN=true; shift ;;
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

# Root-level shared services: source name → deployed subpath under $BASE_DIR/
# Parallel arrays (bash 3 compatible)
# The web interface (minecraft-server-manager) used to be the second entry.
# It was retired — its submodule is gone, so there is nothing to sync from —
# and Step 3d below decommissions whatever an older install left behind.
ROOT_SRC_NAMES=("api-server")
ROOT_DST_NAMES=("services/api-server")
# Systemd service-name suffix (separate from path because 'services/' is not
# part of the service identifier)
ROOT_SVC_NAMES=("api-server")

# Per-service state, filled during the diff pass, consumed by Step 5 / Step 9b.
# Parallel to the arrays above.
ROOT_HAS_BUILD=()     # package.json declares a "build" script
ROOT_SRC_CHANGED=()   # at least one tracked source file added/updated/removed
ROOT_NEEDS_BUILD=()   # dist/ must be regenerated
BUILD_FAILED=false

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

# ── npm / build helpers ──

# True when the component is compiled rather than copied, i.e. its package.json
# declares a "build" script. Such components own a dist/ that is generated, not
# shipped in source.
_has_build_script() {
  local pkg="$1"
  [[ -f "$pkg" ]] || return 1
  node -e "
    const fs = require('fs');
    const p = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    process.exit(p.scripts && p.scripts.build ? 0 : 1);
  " "$pkg" 2>/dev/null
}

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
# $2 = "dev" includes devDependencies — required to run a build.
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

# Per-instance counters
REPLACED=0; ADDED=0; STALE=0
JSON_CONFIGS=()      # "relpath:new_key_count" — per-instance config.json files
JSON_CONFIG_ADDED=0

# Root-level component counters
ROOT_REPLACED=0; ROOT_ADDED=0; ROOT_JSON_ADDED=0; ROOT_STALE=0
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
    common/variables.txt|common/downloaded_versions.json) continue ;;
    interface/*) continue ;;
    update/node_modules/*) continue ;;
    logs/*|backup/logs/*) continue ;;
    */config/config.json) continue ;;
    # Legacy root-level components inside the instance dir — reported as a
    # single REMOVE per component below, not per file
    api-server/*|minecraft-server-manager/*) continue ;;
    */.git|.git|.git/*) continue ;;
  esac
  [[ -f "$NEW_SCRIPTS_SOURCE/$f" ]] && continue
  info "REMOVE  $f  (no longer part of the suite)"
  STALE=$(( STALE + 1 ))
done < <(cd "$TARGET_SCRIPTS_DIR" && find . -type f | sed 's|^\./||' | sort)

# Legacy per-instance copies of the root-level components (pre-services/
# layout). Step 4 removes them; user configs inside are rescued first.
for _legacy in api-server minecraft-server-manager; do
  if [[ -d "$TARGET_SCRIPTS_DIR/$_legacy" ]]; then
    _legacy_files=$(find "$TARGET_SCRIPTS_DIR/$_legacy" -type f ! -path "*/node_modules/*" | wc -l)
    info "REMOVE  ${_legacy}/  (legacy per-instance copy, ${_legacy_files} file(s) — now root-level under services/)"
    STALE=$(( STALE + 1 ))
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

# ── Root-level component diff ──

for i in "${!ROOT_SRC_NAMES[@]}"; do
  src_name="${ROOT_SRC_NAMES[$i]}"
  dst_name="${ROOT_DST_NAMES[$i]}"
  src_dir="$NEW_SCRIPTS_SOURCE/$src_name"
  dst_dir="$BASE_DIR/$dst_name"

  # Initialised before any `continue` so Step 5 / Step 9b can index safely.
  ROOT_HAS_BUILD[$i]=false
  ROOT_SRC_CHANGED[$i]=false
  ROOT_NEEDS_BUILD[$i]=false
  if _has_build_script "$src_dir/package.json"; then ROOT_HAS_BUILD[$i]=true; fi
  _root_changes_before=$(( ROOT_REPLACED + ROOT_ADDED + ROOT_STALE ))

  # Skip if source component doesn't exist or component isn't installed yet.
  # Also check the old location (pre-structure-migration) so we still report
  # what will change even before the directories have been moved.
  [[ ! -d "$src_dir" ]] && continue
  if [[ ! -d "$dst_dir" ]]; then
    # Fall back to old location: services/api-server → api-server, services/manager → manager
    _old_dst="$BASE_DIR/$(basename "$dst_name")"
    [[ -d "$_old_dst" ]] && dst_dir="$_old_dst" || continue
  fi

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

  # Stale files: present in the deployed service, gone from the source.
  # Step 5's wipe-and-replace performs the deletion — but only when it runs,
  # so removals must set NEEDS_ROOT_UPDATE like any other change.
  while IFS= read -r f; do
    case "$f" in
      node_modules/*) continue ;;
      # Build output. Generated from src/, never shipped in source, so every
      # compiled file would otherwise read as "removed upstream". It is carried
      # across the replace step and regenerated below instead.
      dist/*)
        if [[ "${ROOT_HAS_BUILD[$i]}" == true ]]; then continue; fi
        ;;
      # User-generated files preserved across the wipe
      api-server-config.json) continue ;;
      src/config/users.json|src/config/config.json) continue ;;
      logs/*) continue ;;
      */.git|.git|.git/*) continue ;;
    esac
    [[ -f "$src_dir/$f" ]] && continue
    info "REMOVE  $dst_name/$f  (no longer part of the suite)"
    ROOT_STALE=$(( ROOT_STALE + 1 ))
    NEEDS_ROOT_UPDATE=true
  done < <(cd "$dst_dir" && find . -type f | sed 's|^\./||' | sort)

  if [[ $(( ROOT_REPLACED + ROOT_ADDED + ROOT_STALE )) -gt $_root_changes_before ]]; then
    ROOT_SRC_CHANGED[$i]=true
  fi

  # Rebuild when the sources moved or there is no build to keep.
  if [[ "${ROOT_HAS_BUILD[$i]}" == true ]]; then
    if [[ "${ROOT_SRC_CHANGED[$i]}" == true || ! -d "$dst_dir/dist" ]]; then
      info "REBUILD ${dst_name}/dist/  (npm run build)"
      ROOT_NEEDS_BUILD[$i]=true
      NEEDS_ROOT_UPDATE=true
    else
      info "KEEP    ${dst_name}/dist/  (build up to date)"
    fi
  fi

  # Node modules: preserved only while the dependency set is unchanged —
  # Step 5 drops them for a fresh install when package.json or the lockfile
  # differs.
  if [[ -d "$dst_dir/node_modules" ]]; then
    if _pkg_deps_changed "$src_dir" "$dst_dir"; then
      info "DROP    ${dst_name}/node_modules/  (dependencies changed — fresh install will run)"
    else
      info "KEEP    ${dst_name}/node_modules/  (preserved)"
    fi
  fi
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

TOTAL_CHANGES=$(( REPLACED + ADDED + STALE + ROOT_REPLACED + ROOT_ADDED + ROOT_STALE ))

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

NEEDS_SERVER_STOP=false
if $SERVER_RUNNING && [[ "$SKIP_STOP" != true ]] && $NEEDS_INSTANCE_UPDATE; then
  NEEDS_SERVER_STOP=true
fi

if [[ $TOTAL_CHANGES -eq 0 && ${#NEW_VARS[@]} -eq 0 && "$NEEDS_ANY_NPM_INSTALL" != true \
   && "$NEEDS_STRUCT_MIGRATION" != true && "$NEEDS_ROOT_UPDATE" != true ]]; then
  log "Everything is already up to date. Nothing to do."
  exit 0
fi

echo
SUMMARY="$REPLACED file(s) to update, $ADDED file(s) to add, ${#NEW_VARS[@]} variable(s) to add"
[[ $(( STALE + ROOT_STALE )) -gt 0 ]] && \
  SUMMARY="$SUMMARY, $(( STALE + ROOT_STALE )) stale file(s) to remove"
[[ $(( ROOT_REPLACED + ROOT_ADDED )) -gt 0 ]] && \
  SUMMARY="$SUMMARY, $ROOT_REPLACED service file(s) to update"
[[ $(( JSON_CONFIG_ADDED + ROOT_JSON_ADDED )) -gt 0 ]] && \
  SUMMARY="$SUMMARY, $(( JSON_CONFIG_ADDED + ROOT_JSON_ADDED )) config key(s) to merge"
"$NEEDS_INSTANCE_MOVE" && SUMMARY="$SUMMARY, instance dir to relocate" || true
info "$SUMMARY"
echo

# ── Confirm ──

if [[ "$SKIP_CONFIRM" != true ]]; then
  echo -e "${BOLD}This will:${NC}"
  echo "  1. Create a compressed archive backup of the scripts dir"
  if $NEEDS_SERVER_STOP; then
    echo "  2. Stop the Minecraft server"
  elif $SERVER_RUNNING; then
    echo "  2. Leave the Minecraft server running (instance not affected)"
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
    echo "                 update/node_modules/, logs/"
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
  if $NEEDS_ROOT_UPDATE; then
    echo "  5. Update shared services:"
    for i in "${!ROOT_DST_NAMES[@]}"; do
      dst_dir="$BASE_DIR/${ROOT_DST_NAMES[$i]}"
      # Show the destination path (new or old, whichever will exist after migration)
      echo "       $dst_dir"
    done
    echo "     Preserving: node_modules/, dist/, api-server-config.json,"
    echo "                 services/manager/src/config/users.json"
    echo "     Merging (not replacing): services/manager/src/config/config.json"
    [[ $ROOT_STALE -gt 0 ]] && \
      echo "     Removing $ROOT_STALE stale service file(s) no longer part of the suite"
    for i in "${!ROOT_DST_NAMES[@]}"; do
      [[ "${ROOT_NEEDS_BUILD[$i]:-false}" == true ]] && \
        echo "     Rebuilding ${ROOT_DST_NAMES[$i]}/dist/ (npm run build)"
    done
  fi
  [[ $(( STALE + ROOT_STALE )) -gt 0 ]] && \
    echo "     (all removed files remain available in the backup archive)"
  echo "  6. Add ${#NEW_VARS[@]} new variable(s) to variables.txt"
  $NEEDS_ANY_NPM_INSTALL && echo "  7. Run npm install in changed per-instance subdirs"
  $NEEDS_SERVER_STOP && echo "  9. Restart the Minecraft server"
  if $NEEDS_ROOT_UPDATE && [[ "$SKIP_SERVICE_RESTART" != true ]]; then
    echo " 9b. Restart the updated shared services"
  fi
  echo
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  echo
fi

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
  run_cmd sudo systemctl stop "${INSTANCE_NAME}.service" 2>/dev/null || true
  sleep 2; log "Server stopped"
elif $SERVER_RUNNING && [[ "$SKIP_STOP" == true ]]; then
  echo; echo -e "${BOLD}Step 2: Stop server${NC}"
  warn "Server running but --no-stop specified. Files replaced live."
elif $SERVER_RUNNING; then
  echo; echo -e "${BOLD}Step 2: Stop server${NC}"
  log "Instance not affected by this migration — leaving '$INSTANCE_NAME' running"
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

# Wipe and replace
log "Removing old per-instance scripts..."
$DRY_RUN || find "$TARGET_SCRIPTS_DIR" -mindepth 1 -delete
log "Copying new per-instance scripts..."
$DRY_RUN || cp -a "$NEW_SCRIPTS_SOURCE/." "$TARGET_SCRIPTS_DIR/"

# Remove root-level component source trees that got copied into the scripts dir
# (they're submodules in src/scripts/ but don't belong inside scripts/INSTANCE_NAME/)
for src_name in "${ROOT_SRC_NAMES[@]}"; do
  [[ -d "$TARGET_SCRIPTS_DIR/$src_name" ]] && {
    # SC2115 fix: :? aborts if TARGET_SCRIPTS_DIR is somehow empty, preventing rm -rf /…
    $DRY_RUN || rm -rf "${TARGET_SCRIPTS_DIR:?}/$src_name"
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
}

if $NEEDS_INSTANCE_UPDATE; then
  replace_instance_scripts
else
  echo; echo -e "${BOLD}Step 4: Replace per-instance scripts${NC}"
  log "No per-instance changes — scripts left untouched"
fi

# ── Step 5: Update shared services ──

if $NEEDS_ROOT_UPDATE; then
  echo; echo -e "${BOLD}Step 5: Update shared services${NC}"

  for i in "${!ROOT_SRC_NAMES[@]}"; do
    src_name="${ROOT_SRC_NAMES[$i]}"
    dst_name="${ROOT_DST_NAMES[$i]}"
    src_dir="$NEW_SCRIPTS_SOURCE/$src_name"
    dst_dir="$BASE_DIR/$dst_name"

    [[ ! -d "$src_dir" ]] && continue
    # After structural migration the new path should exist; but if it doesn't,
    # fall back to the old location one final time.
    if [[ ! -d "$dst_dir" ]]; then
      _fallback="$BASE_DIR/$(basename "$dst_name")"
      [[ -d "$_fallback" ]] && dst_dir="$_fallback" || continue
    fi

    log "Updating $dst_name/ ($dst_dir)"

    ROOT_PRESERVE=$(mktemp -d)

    # Decide the npm question NOW, against the DEPLOYED package.json —
    # after the wipe-and-copy below, dst always equals src, so a
    # post-copy diff can never detect a change. (This is exactly how the
    # old JS-era node_modules survived the TypeScript rewrite: the stale
    # tree was restored and npm install never ran.)
    pkg_changed=false
    if _pkg_deps_changed "$src_dir" "$dst_dir"; then pkg_changed=true; fi

    # node_modules: only worth preserving when the dependency set is
    # unchanged — a changed package.json/lockfile gets a fresh install
    # instead of a stale restore.
    if [[ -d "$dst_dir/node_modules" ]]; then
      if $pkg_changed; then
        info "  Dropping node_modules/ (dependencies changed — fresh install will run)"
      else
        $DRY_RUN || cp -a "$dst_dir/node_modules" "$ROOT_PRESERVE/node_modules"
        info "  Saved: node_modules/"
      fi
    fi

    # dist/ is generated output. It is carried across the wipe so the service
    # stays runnable if the rebuild below fails.
    if [[ -d "$dst_dir/dist" ]]; then
      $DRY_RUN || cp -a "$dst_dir/dist" "$ROOT_PRESERVE/dist"
      info "  Saved: dist/ (current build)"
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

    # Restore dist — replaced by the rebuild below when one is due
    if [[ -d "$ROOT_PRESERVE/dist" ]]; then
      $DRY_RUN || cp -a "$ROOT_PRESERVE/dist" "$dst_dir/dist"
      info "  Restored: dist/ (previous build)"
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

    # npm / build. A build needs devDependencies, the runtime does not — so
    # install everything, build, then prune back to production deps. On a
    # failed build the previous dist/ (restored above) stays in place.
    if [[ -f "$src_dir/package.json" ]]; then
      needs_npm=false
      $pkg_changed && needs_npm=true
      [[ ! -d "$dst_dir/node_modules" ]] && needs_npm=true

      if [[ "${ROOT_NEEDS_BUILD[$i]:-false}" == true ]]; then
        if command -v npm &>/dev/null; then
          log "  npm install (with devDependencies) in $dst_name/"
          _npm_install "$dst_dir" dev
          log "  npm run build in $dst_name/"
          if $DRY_RUN; then
            echo "[DRY-RUN] (cd $dst_dir && npm run build)"
          elif ( cd "$dst_dir" && npm run build ); then
            log "  Build succeeded — dist/ regenerated"
            if npm prune --omit=dev --prefix "$dst_dir" &>/dev/null; then
              info "  Pruned devDependencies"
            else
              warn "  Could not prune devDependencies (harmless)"
            fi
          else
            err "  Build FAILED — previous dist/ left in place, service runs old code"
            info "  Fix, then: (cd '$dst_dir' && npm run build)"
            BUILD_FAILED=true
          fi
        else
          warn "  npm not found — run: (cd '$dst_dir' && npm install && npm run build)"
          BUILD_FAILED=true
        fi
      elif $needs_npm; then
        if command -v npm &>/dev/null; then
          log "  npm install --omit=dev in $dst_name/"
          _npm_install "$dst_dir"
        else
          warn "  npm not found — run: npm install --omit=dev --prefix '$dst_dir'"
        fi
      fi
    fi

    log "  $dst_name/ updated"
  done
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

# Compiled services must have a non-empty dist/ or they won't start
for i in "${!ROOT_DST_NAMES[@]}"; do
  [[ "${ROOT_HAS_BUILD[$i]:-false}" == true ]] || continue
  _svc_dir="$BASE_DIR/${ROOT_DST_NAMES[$i]}"
  [[ -d "$_svc_dir" ]] || continue
  if [[ -d "$_svc_dir/dist" && -n "$(ls -A "$_svc_dir/dist" 2>/dev/null)" ]]; then
    info "✓ ${ROOT_DST_NAMES[$i]}/dist/ present"
  else
    err "${ROOT_DST_NAMES[$i]}/dist/ is missing or empty — the service will not start"
    verify_ok=false
  fi
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

# ── Step 9b: Restart updated shared services ──
# Restarts only the units whose code actually changed. The Minecraft instance
# is unaffected either way.

RESTART_HINTS=()
if $NEEDS_ROOT_UPDATE; then
  echo; echo -e "${BOLD}Step 9b: Restart shared services${NC}"
  for i in "${!ROOT_DST_NAMES[@]}"; do
    if [[ "${ROOT_SRC_CHANGED[$i]:-false}" != true && "${ROOT_NEEDS_BUILD[$i]:-false}" != true ]]; then
      continue
    fi
    _svc="$(basename "$BASE_DIR")-${ROOT_SVC_NAMES[$i]}.service"
    if [[ "$SKIP_SERVICE_RESTART" == true ]]; then
      info "Skipped (--no-service-restart): $_svc"
      RESTART_HINTS+=("$_svc")
    elif $BUILD_FAILED; then
      warn "Not restarting $_svc after a failed build"
      RESTART_HINTS+=("$_svc")
    elif [[ -f "/etc/systemd/system/$_svc" ]]; then
      log "Restarting $_svc"
      run_cmd sudo systemctl restart "$_svc"
      if ! $DRY_RUN; then
        sleep 2
        systemctl is-active "$_svc" &>/dev/null \
          && info "  $_svc is active" \
          || warn "  $_svc did not come up — check: systemctl status $_svc"
      fi
    else
      warn "No systemd unit $_svc — restart ${ROOT_DST_NAMES[$i]} manually"
      RESTART_HINTS+=("$_svc")
    fi
  done
fi

# ── Done ──

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}${BOLD}Migration complete!${NC}"
echo
info "Backup archive: $BACKUP_ARCHIVE"
info "Remove once verified: rm -f '$BACKUP_ARCHIVE'"
echo
if $BUILD_FAILED; then
  err "At least one service build failed — it is still running its previous dist/."
  info "Check the build output above before relying on the new code."
  echo
fi
if [[ ${#RESTART_HINTS[@]} -gt 0 ]]; then
  warn "These services were updated but not restarted:"
  for _svc in "${RESTART_HINTS[@]}"; do info "  sudo systemctl restart $_svc"; done
  echo
fi
if $SERVER_RUNNING && ! $NEEDS_SERVER_STOP; then
  info "Minecraft instance '$INSTANCE_NAME' was left running — nothing it uses changed."
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
