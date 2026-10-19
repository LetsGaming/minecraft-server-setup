#!/bin/bash
# Plan phase for the per-instance scripts: what is added, updated, stale or kept.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

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
NPM_SUBDIRS=()
NEEDS_ANY_NPM_INSTALL=false

# Walks the new source tree: adds, updates and config merges.
plan_script_diff() {
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
  return 0
}

# Walks the deployed tree: files the suite no longer ships.
plan_stale_files() {
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
  return 0
}

plan_legacy_components() {
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
  return 0
}

plan_npm_subdirs() {
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
  return 0
}

plan_interface() {
  if [[ -d "$TARGET_SCRIPTS_DIR/interface" ]]; then
    HAS_INTERFACE=true
    info "KEEP    interface/  (web interface — preserved)"
  fi
  return 0
}

plan_instance_scripts() {
  echo -e "${BOLD}Changes to be applied${NC}"
  plan_script_diff
  plan_stale_files
  plan_legacy_components
  plan_npm_subdirs
  plan_interface
  return 0
}
