#!/bin/bash
# Step 8: check the migrated install before declaring success.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# Step 8.
verify_migration() {
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
  return 0
}
