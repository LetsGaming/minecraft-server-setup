#!/bin/bash
set -e

# Deploys the API wrapper. With API_SERVER.SERVICE_USER set the wrapper gets its
# own unprivileged user (docs/service-user.md): the user and its grants are made
# before the wrapper is deployed and again after (the wrapper's own folder only
# exists once it is deployed), and the service starts only when both are done.
setup_api_wrapper() {
  local svc scripts_dir node_path bash_path
  # The wrapper refuses to start without a key; --api-server on a config that has
  # none (the Default route writes an empty one) would deploy a crash loop.
  run_or_echo "node \"$SCRIPT_DIR/src/setup/management/ensure_api_key.js\" \"$SCRIPT_DIR/variables.json\""
  svc=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.SERVICE_USER || '')" 2>/dev/null)
  if [ -z "$svc" ]; then
    run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_api_server_service.js\""
    return
  fi

  scripts_dir="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME"
  node_path=$(command -v node)
  bash_path=$(command -v bash)
  local su="sudo bash \"$SCRIPT_DIR/src/setup/management/service_user.sh\" --scripts-dir \"$scripts_dir\" --user \"$svc\" --node-path \"$node_path\" --bash-path \"$bash_path\""
  log "Creating the wrapper's service user '$svc' and its grants..."
  run_or_echo "$su"
  run_or_echo "node \"$SCRIPT_DIR/src/setup/management/create_api_server_service.js\""
  log "Granting '$svc' access to the deployed wrapper..."
  run_or_echo "$su"
  run_or_echo "sudo systemctl restart \"${TARGET_DIR_NAME}-api-server.service\""
}

# variables.json holds this install's secrets, so it is not tracked by git
# (S-028); a fresh clone has only variables.example.json. Create the live file
# from it on the first run and stop, so it is edited before anything happens.
ensure_variables_json() {
  local live="$SCRIPT_DIR/variables.json" example="$SCRIPT_DIR/variables.example.json"
  [[ -f "$live" ]] && return 0
  if [[ ! -f "$example" ]]; then
    error "variables.json is missing and there is no variables.example.json to start from."
    exit 1
  fi
  ( umask 077; cp "$example" "$live" )
  warn "Created variables.json from variables.example.json."
  warn "Edit it (instance name, RCON, API key, ...), then run this again."
  exit 1
}

# Validate variables.json once, up front, and export the two fields the setup
# steps need (INSTANCE_NAME, TARGET_DIR_NAME). Previously the first call to
# loadVariables() happened implicitly inside create_directories.js; now that the
# early steps are bash, we resolve + validate here instead. loadVariables()
# throws on an invalid config, so a bad variables.json fails fast here rather
# than after downloading a whole modpack.

resolve_instance_vars() {
  # Already resolved (e.g. both setup flows share run_setup_startup)
  if [[ -n "$INSTANCE_NAME" && -n "$TARGET_DIR_NAME" ]]; then
    return 0
  fi

  local out
  if ! out=$(node -e '
      const v = require(process.env.SCRIPT_DIR + "/src/setup/common/loadVariables")();
      process.stdout.write((v.INSTANCE_NAME || "") + "\n" + (v.TARGET_DIR_NAME || ""));
    ' 2>/dev/null); then
    error "variables.json is missing or invalid."
    error "Run 'bash main.sh --check' to see the exact problem."
    exit 1
  fi

  INSTANCE_NAME="$(printf '%s\n' "$out" | sed -n '1p')"
  TARGET_DIR_NAME="$(printf '%s\n' "$out" | sed -n '2p')"

  if [[ -z "$INSTANCE_NAME" || -z "$TARGET_DIR_NAME" ]]; then
    error "Could not read INSTANCE_NAME / TARGET_DIR_NAME from variables.json."
    exit 1
  fi

  export INSTANCE_NAME TARGET_DIR_NAME
}

run_modpack_setup() {
  run_setup_startup
  
  log "Downloading modpack..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/download/download_modpack.js\""

  log "Downloading additional mods..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/download/download_mods.js\""

  run_setup_steps

  log "Unpacking modpack..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/structure/unpack_modpack.sh\""
}

run_vanilla_setup() {
  run_setup_startup

  log "Downloading Jabba..."
  run_or_echo "bash \"$SCRIPT_DIR/src/vanilla/download/install_jabba.sh\""

  log "Installing Java..."
  run_or_echo "node \"$SCRIPT_DIR/src/vanilla/download/install_java.js\""

  log "Downloading server jar..."
  run_or_echo "node \"$SCRIPT_DIR/src/vanilla/download/download_server.js\""

  run_setup_steps

  log "Setting additional variables..."
  run_or_echo "node \"$SCRIPT_DIR/src/vanilla/variables/set_vanilla_server_variables.js\""

  log "Moving server files..."
  run_or_echo "bash \"$SCRIPT_DIR/src/vanilla/structure/move_files.sh\""
}

run_server_setup() {
  if [ "$MODPACK" = true ]; then run_modpack_setup; else run_vanilla_setup; fi
}

run_post_mod_config() {
  local instance_dir="$MAIN_DIR/$TARGET_DIR_NAME/instances/$INSTANCE_NAME" jar found=false globs
  globs=$(shopt -p nullglob nocaseglob || true)
  shopt -s nullglob nocaseglob
  for jar in "$instance_dir"/mods/*xaero*minimap*.jar "$instance_dir"/mods/*xaero*world*map*.jar; do
    [[ -f "$jar" ]] && found=true
  done
  eval "$globs"
  [[ "$found" = true ]] || return 0

  log "Patching Xaero config keys..."
  if ! run_or_echo "bash \"$SCRIPT_DIR/src/scripts/misc/xaero_config.sh\" apply \"$instance_dir\""; then
    warn "Could not patch the Xaero config keys; run 'xaero_config.sh check' on the instance later."
  fi
}

run_server_cleanup() {
  if [ "$MODPACK" = true ]; then run_modpack_cleanup; else run_vanilla_cleanup; fi
}

run_setup_startup() {
  resolve_instance_vars

  log "Downloading required packages..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/download/download_packages.sh\""


  log "Creating server directory structure..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/structure/create_directories.sh\""
}

run_setup_steps() {
  log "Setting variables..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_common_variables.js\""
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_update_variables.js\""
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_server_variables.js\""

  log "Setting server.properties..."
  run_or_echo "node \"$SCRIPT_DIR/src/setup/variables/set_server_properties.js\""

  log "Copying startup scripts..."
  run_or_echo "bash \"$SCRIPT_DIR/src/setup/structure/copy_scripts.sh\""
}

run_optional_setup() {
  if [ "$NO_SERVICE" = false ]; then
    log "Creating systemd service..."
    run_or_echo "bash \"$SCRIPT_DIR/src/setup/management/create_service.sh\""
  else
    warn "Skipping systemd service creation (--no-service)."
  fi

  if [ "$NO_BACKUP" = false ]; then
    log "Creating backup job..."
    run_or_echo "bash \"$SCRIPT_DIR/src/setup/management/create_backup_job.sh\""
  else
    warn "Skipping backup job creation (--no-backup)."
  fi

  if [ "$EULA" = true ]; then
    log "EULA accepted. Applying configuration..."
    run_or_echo "bash \"$SCRIPT_DIR/src/setup/management/agree_eula.sh\""
  else
    warn "EULA not accepted. Please do so before launching the server."
  fi

  # --y skips the prompt, so ENABLED in variables.json is re-checked here.
  if [ "$SETUP_API_SERVER" = true ] || api_server_enabled_in_config; then
    log "Setting up minecraft-bot API wrapper service..."
    setup_api_wrapper
  else
    warn "Skipping API wrapper setup (use --api-server or set API_SERVER.ENABLED=true)."
  fi

  # Setup restart cron if enabled
  local restart_enabled
  restart_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.RESTART_SCHEDULE?.ENABLED || false)" 2>/dev/null)
  if [ "$restart_enabled" = "true" ]; then
    log "Setting up scheduled restart cron..."
    run_or_echo "bash \"$SCRIPT_DIR/src/setup/management/create_restart_job.sh\""
  fi
}

# ── Rollback bookkeeping (S-001) ────────────────────────────────────────────
# Re-running setup to add an instance is a supported flow, so a failed run must
# undo only what that run created. The old rollback removed the whole base
# directory, which took every other instance, world and backup with it. These
# record what already existed before the run touched anything.
_ROLLBACK_ARMED=false
_PRE_BASE_EXISTED=false
declare -A _PRE_PATH_EXISTED=()
declare -A _PRE_UNIT_EXISTED=()
_PRE_CRONTAB_FILE=""
_PRE_CRONTAB_EXISTED=false
# The shared wrapper's config, which a run for a new instance adds itself to.
_PRE_API_CONFIG_COPY=""

# Paths a setup run for this instance creates, in the order they are removed.
_rollback_paths() {
  local base="$MAIN_DIR/$TARGET_DIR_NAME"
  printf '%s\n' \
    "$base/instances/$INSTANCE_NAME" \
    "$base/scripts/$INSTANCE_NAME" \
    "$base/backups/$INSTANCE_NAME" \
    "$base/services/api-server" \
    "$base/services"
  local custom
  custom=$(node -e "try{const p=require('$SCRIPT_DIR/variables.json').BACKUPS?.BACKUPS_PATH;if(p&&p!=='none')process.stdout.write(p)}catch(e){}" 2>/dev/null || true)
  [[ -n "$custom" ]] && printf '%s\n' "$custom"
  return 0
}

_rollback_units() {
  printf '%s\n' "$INSTANCE_NAME" "${TARGET_DIR_NAME}-api-server" "${TARGET_DIR_NAME}-manager"
}

# Call once, after the config is validated and before the first change.
snapshot_setup_state() {
  resolve_instance_vars
  local base="$MAIN_DIR/$TARGET_DIR_NAME"
  [[ -e "$base" ]] && _PRE_BASE_EXISTED=true
  local p u
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -e "$p" ]]; then _PRE_PATH_EXISTED["$p"]=true; else _PRE_PATH_EXISTED["$p"]=false; fi
  done < <(_rollback_paths)
  while IFS= read -r u; do
    if [[ -e "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${u}.service" ]]; then _PRE_UNIT_EXISTED["$u"]=true; else _PRE_UNIT_EXISTED["$u"]=false; fi
  done < <(_rollback_units)
  local api_config="$base/services/api-server/api-server-config.json"
  if [[ -f "$api_config" ]]; then
    _PRE_API_CONFIG_COPY=$(mktemp)
    # shellcheck disable=SC2024  # sudo reads the file; the copy is ours on purpose
    sudo cat "$api_config" > "$_PRE_API_CONFIG_COPY" 2>/dev/null || _PRE_API_CONFIG_COPY=""
  fi
  _PRE_CRONTAB_FILE=$(mktemp)
  if crontab -l > "$_PRE_CRONTAB_FILE" 2>/dev/null; then _PRE_CRONTAB_EXISTED=true; fi
  _ROLLBACK_ARMED=true
  if [[ "$_PRE_BASE_EXISTED" == true ]]; then
    warn "$base already exists. If this run fails, only what it created is rolled back;"
    warn "existing instances, worlds and backups are left as they are."
  fi
}

# True when a path is safe to hand to rm -rf: absolute, under MAIN_DIR, and
# not MAIN_DIR, the base dir or / itself.
_rollback_path_ok() {
  local p="$1" base="$MAIN_DIR/$TARGET_DIR_NAME"
  [[ "$p" == /* && "$p" != "/" && "$p" != "$MAIN_DIR" && "$p" != "$MAIN_DIR/" && "$p" != "$base" && "$p" != "$base/" ]] || return 1
  [[ "$p" != *"/../"* && "$p" != *"/.." && "$p" != *"/./"* && "$p" != *"/." ]]
}

run_rollback() {
  warn "Setup failed — rolling back what this run changed..."

  if [[ "$_ROLLBACK_ARMED" != true ]]; then
    warn "Nothing was recorded before the failure — leaving everything in place."
    warn "You may need to clean up manually."
    return 0
  fi

  local base="$MAIN_DIR/$TARGET_DIR_NAME"

  # Units this run installed. A unit that existed before (the shared
  # api-server unit of an earlier instance) is left running and in place.
  local u removed_unit=false
  while IFS= read -r u; do
    [[ "${_PRE_UNIT_EXISTED[$u]:-true}" == false ]] || continue
    if [[ -e "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${u}.service" ]]; then
      log "Removing service: ${u}.service"
      sudo systemctl stop    "${u}.service" 2>/dev/null || true
      sudo systemctl disable "${u}.service" 2>/dev/null || true
      sudo rm -f "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${u}.service"
      removed_unit=true
    fi
  done < <(_rollback_units)
  [[ "$removed_unit" == true ]] && { sudo systemctl daemon-reload 2>/dev/null || true; }

  # The crontab goes back to exactly what it was, rather than losing every
  # line that mentions the base dir (other instances' backups included).
  if [[ -n "$_PRE_CRONTAB_FILE" ]]; then
    if [[ "$_PRE_CRONTAB_EXISTED" == true ]]; then
      crontab "$_PRE_CRONTAB_FILE" 2>/dev/null || warn "Could not restore the previous crontab."
    else
      crontab -r 2>/dev/null || true
    fi
    rm -f "$_PRE_CRONTAB_FILE"
  fi

  # The shared wrapper's config goes back to what it was, without this
  # run's instance in it; contents only, so its owner, mode and ACL stay.
  local api_config="$base/services/api-server/api-server-config.json"
  if [[ -n "$_PRE_API_CONFIG_COPY" ]]; then
    if [[ -f "$api_config" ]] && ! cmp -s "$_PRE_API_CONFIG_COPY" "$api_config"; then
      log "Restoring $api_config"
      sudo tee "$api_config" < "$_PRE_API_CONFIG_COPY" > /dev/null || warn "Could not restore $api_config."
    fi
    rm -f "$_PRE_API_CONFIG_COPY"
  fi

  if [[ "$_PRE_BASE_EXISTED" == false ]]; then
    # Everything under the base dir is this run's.
    if [[ -d "$base" ]] && _rollback_path_ok "$base/x"; then
      log "Removing $base (created by this run)"
      sudo rm -rf -- "$base"
    fi
  fi
  # Paths outside the base dir (a custom BACKUPS_PATH), and the per-instance
  # paths of a run into an existing base dir: only those this run created.
  local p
  for p in "${!_PRE_PATH_EXISTED[@]}"; do
    [[ "${_PRE_PATH_EXISTED[$p]}" == false && -e "$p" ]] || continue
    if _rollback_path_ok "$p"; then
      log "Removing $p (created by this run)"
      sudo rm -rf -- "$p"
    else
      warn "Not removing '$p': not a path this rollback may delete."
    fi
  done

  # Remove source-tree artifacts written during setup
  local src_common="$SCRIPT_DIR/src/scripts/common"
  sudo rm -f "$src_common/variables.txt"
  sudo rm -f "$src_common/curseforge.txt"
  sudo rm -f "$src_common/downloaded_versions.json"
  sudo rm -rf "$SCRIPT_DIR/src/vanilla/temp"
  sudo rm -rf "$SCRIPT_DIR/src/setup/download/temp"

  warn "Rollback complete. Re-run the setup script when you are ready."
}

run_modpack_cleanup() {
  log "Cleaning up temporary files..."
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/setup/download/temp\""
  run_cleanup
}

run_vanilla_cleanup() {
  log "Cleaning up temporary files..."
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/temp\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/vanilla/temp\""
  run_cleanup
}

run_cleanup() {
  # These files are written into the source tree during setup and contain
  # secrets (RCON password, API key, CurseForge key). They have already been
  # copied into the deployed instance dir, so remove the source-tree copies on
  # the success path too — previously only run_rollback removed variables.txt,
  # leaving secrets in the working tree after a successful run.
  run_or_echo "sudo rm -f \"$SCRIPT_DIR/src/scripts/common/variables.txt\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/scripts/common/downloaded_versions.json\""
  run_or_echo "sudo rm -rf \"$SCRIPT_DIR/src/scripts/common/curseforge.txt\""

  # The rollback snapshots (a crontab copy and a copy of the wrapper's config,
  # which holds its API key) have no use once setup succeeded.
  local snapshot
  for snapshot in "$_PRE_CRONTAB_FILE" "$_PRE_API_CONFIG_COPY"; do
    if [[ -n "$snapshot" ]]; then rm -f -- "$snapshot"; fi
  done
  _PRE_CRONTAB_FILE=""
  _PRE_API_CONFIG_COPY=""
}

maybe_start_server() {
  # Read instance/target names from variables.json for display purposes
  local instance_name target_dir
  instance_name=$(node -e "console.log(require('$SCRIPT_DIR/variables.json').INSTANCE_NAME)")
  target_dir=$(node -e "console.log(require('$SCRIPT_DIR/variables.json').TARGET_DIR_NAME)")

  if [ "$NO_START" = false ]; then
    if sudo -v &>/dev/null; then
      log "Starting the server..."
      if run_or_echo "NO_SERVICE=\"$NO_SERVICE\" bash \"$SCRIPT_DIR/src/setup/management/start_server.sh\""; then
        if [ "$EULA" = false ]; then
          echo
          warn "Server started but EULA not yet accepted."
          echo "Attach to the server with:"
          echo "  screen -r $instance_name"
          echo "Then type 'I agree' and press Enter."
        fi
      else
        warn "The server did not start (see above). Setup itself finished."
      fi
    else
      error "Insufficient sudo privileges to start the server."
      exit 1
    fi
  else
    log "Server will not be started (--no-start)."
    echo "You can start it manually with:"
    echo "  bash $HOME/$target_dir/scripts/$instance_name/start.sh"
    if [ "$NO_SERVICE" = false ]; then
      echo "Or use the systemd service with:"
      echo "  sudo systemctl start $instance_name.service"
    fi
  fi
}

# ── Preflight validation (--check mode) ──

run_preflight_check() {
  local errors=0
  local warnings=0

  echo "=== Preflight Check ==="
  echo

  # 1. Check variables.json
  echo "[CHECK] Validating variables.json..."
  if node -e "require('$SCRIPT_DIR/src/setup/common/loadVariables')()" 2>/dev/null; then
    echo "  ✓ variables.json is valid"
  else
    echo "  ✗ variables.json validation failed"
    node -e "require('$SCRIPT_DIR/src/setup/common/loadVariables')()" 2>&1 | sed 's/^/    /'
    errors=$((errors + 1))
  fi

  # 2. Check Node.js
  echo "[CHECK] Node.js..."
  if command -v node &>/dev/null; then
    local node_version
    node_version=$(node -v)
    echo "  ✓ Node.js $node_version found"
  else
    echo "  ✗ Node.js not found"
    errors=$((errors + 1))
  fi

  # 3. Check npm dependencies
  echo "[CHECK] npm dependencies..."
  if [ -d "$SCRIPT_DIR/node_modules" ]; then
    echo "  ✓ node_modules present"
  else
    echo "  ✗ node_modules not found — run 'npm install'"
    errors=$((errors + 1))
  fi

  # 4. Check required tools
  echo "[CHECK] Required tools..."
  # cron and setfacl live in /usr/sbin, which a normal user's PATH can lack.
  local tool_path="$PATH:${PREFLIGHT_EXTRA_PATH:-/usr/sbin:/sbin}"
  for tool in screen rsync zstd tar curl jq unzip cron setfacl; do
    if PATH="$tool_path" command -v "$tool" &>/dev/null; then
      echo "  ✓ $tool"
    else
      echo "  ✗ $tool not found"
      errors=$((errors + 1))
    fi
  done

  # 5. Check CurseForge API config (only needed with --modpack)
  echo "[CHECK] CurseForge config..."
  local cf_config="$SCRIPT_DIR/src/setup/download/json/curseforge_variables.json"
  if [ "${MODPACK:-false}" != true ]; then
    echo "  - skipped (vanilla/Fabric setup; use --modpack for a CurseForge pack)"
  elif [ -f "$cf_config" ]; then
    local api_key pack_id
    api_key=$(node -e "console.log(require('$cf_config').api_key)" 2>/dev/null)
    pack_id=$(node -e "console.log(require('$cf_config').pack_id)" 2>/dev/null)
    if [[ "$api_key" == "none" || -z "$api_key" ]]; then
      echo "  ⚠ API key not set (required for modpack setup)"
      warnings=$((warnings + 1))
    else
      echo "  ✓ API key configured"
    fi
    if [[ "$pack_id" == "none" || -z "$pack_id" ]]; then
      echo "  ⚠ Pack ID not set (required for modpack setup)"
      warnings=$((warnings + 1))
    else
      echo "  ✓ Pack ID configured ($pack_id)"
    fi
  else
    echo "  ⚠ curseforge_variables.json not found"
    warnings=$((warnings + 1))
  fi

  # 6. Check disk space
  echo "[CHECK] Disk space..."
  local avail_gb
  avail_gb=$(df -BG "$HOME" | tail -1 | awk '{print $4}' | tr -d 'G')
  if (( avail_gb < 5 )); then
    echo "  ✗ Only ${avail_gb}GB available — need at least 5GB"
    errors=$((errors + 1))
  else
    echo "  ✓ ${avail_gb}GB available"
  fi

  # 7. Check RCON config
  echo "[CHECK] RCON config..."
  local use_rcon
  use_rcon=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.SERVER_CONTROL?.USE_RCON || false)" 2>/dev/null)
  if [ "$use_rcon" = "true" ]; then
    local rcon_pw
    rcon_pw=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.SERVER_CONTROL?.RCON_PASSWORD || '')" 2>/dev/null)
    if [[ -z "$rcon_pw" ]]; then
      echo "  ✗ RCON enabled but no password set"
      errors=$((errors + 1))
    else
      echo "  ✓ RCON enabled (port $(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.SERVER_CONTROL?.RCON_PORT || 25575)" 2>/dev/null))"
    fi
  else
    echo "  ✓ Using screen mode (RCON disabled)"
  fi

  # 8. Check webhook config
  echo "[CHECK] Webhook config..."
  local webhook_url
  webhook_url=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.NOTIFICATIONS?.WEBHOOK_URL || '')" 2>/dev/null)
  if [[ -n "$webhook_url" && "$webhook_url" != "none" ]]; then
    echo "  ✓ Webhook configured"
  else
    echo "  ⚠ No webhook URL configured (notifications disabled)"
    warnings=$((warnings + 1))
  fi

  # 9. Check API server config
  echo "[CHECK] API server config..."
  local api_enabled api_port api_key
  api_enabled=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.ENABLED || false)" 2>/dev/null)
  if [ "$api_enabled" = "true" ]; then
    api_port=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.PORT || 3000)" 2>/dev/null)
    api_key=$(node -e "const v=require('$SCRIPT_DIR/variables.json'); console.log(v.API_SERVER?.API_KEY || '')" 2>/dev/null)
    if [[ -z "$api_key" ]]; then
      echo "  ⚠ API_SERVER enabled but no API_KEY set (the wrapper will refuse to start)"
      warnings=$((warnings + 1))
    elif [[ "$api_key" == "replace-with-a-long-random-secret" ]]; then
      echo "  ✗ API_KEY is still the example's placeholder — generate one: openssl rand -hex 32"
      warnings=$((warnings + 1))
    elif [[ ${#api_key} -lt 32 ]]; then
      echo "  ⚠ API_KEY is shorter than 32 characters — the wrapper will refuse to start (openssl rand -hex 32)"
      warnings=$((warnings + 1))
    else
      echo "  ✓ API server enabled (port $api_port, key configured)"
    fi
    # Check that node is available (required to run the wrapper)
    if ! command -v node &>/dev/null; then
      echo "  ✗ node not found — required to run the API wrapper"
      errors=$((errors + 1))
    fi
  else
    echo "  ✓ API server disabled (set API_SERVER.ENABLED=true to enable)"
  fi

  # 10. Retired web interface — warn if its service is left over
  echo "[CHECK] Retired web interface..."
  if systemctl list-unit-files "${TARGET_DIR_NAME}-manager.service" &>/dev/null; then
    echo "  ! ${TARGET_DIR_NAME}-manager.service still exists"
    echo "    Run migrate.sh, or remove it by hand — see docs/retiring-web-interface.md"
  fi

  # Summary
  echo
  echo "=== Result ==="
  if [ $errors -eq 0 ]; then
    echo "✓ All checks passed ($warnings warning(s)). Ready to run setup."
    return 0
  else
    echo "✗ $errors error(s), $warnings warning(s). Fix errors before running setup."
    return 1
  fi
}
