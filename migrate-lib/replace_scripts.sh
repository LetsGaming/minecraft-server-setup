#!/bin/bash
# Step 4: build the new scripts tree next to the old one and swap it in.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

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
  # The operation locks are held on the files in the old .locks/. Move that
  # folder into the new tree (a rename keeps the files the held locks are on)
  # instead of leaving a copy there, or everything after the swap would run
  # unlocked.
  if [[ -d "$TARGET_SCRIPTS_DIR/.locks" ]]; then
    rm -rf -- "${STAGING_SCRIPTS_DIR:?}/.locks"
    mv -- "$TARGET_SCRIPTS_DIR/.locks" "$STAGING_SCRIPTS_DIR/.locks"
  fi
  mv -- "$TARGET_SCRIPTS_DIR" "${TARGET_SCRIPTS_DIR%/}.old.$$"
  mv -- "$STAGING_SCRIPTS_DIR" "$TARGET_SCRIPTS_DIR"
  rm -rf -- "${TARGET_SCRIPTS_DIR%/}.old.$$"
fi
rm -rf -- "$PRESERVE_DIR"
log "Per-instance scripts replaced"
}

run_replace_scripts() {
  if $NEEDS_INSTANCE_UPDATE; then
    replace_instance_scripts
  else
    echo; echo -e "${BOLD}Step 4: Replace per-instance scripts${NC}"
    log "No per-instance changes — scripts left untouched"
  fi
  return 0
}
