#!/bin/bash
# New variables that get appended to variables.txt (plan and step 6).
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

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

plan_new_variables() {
  for entry in "${NEW_VAR_DEFAULTS[@]}"; do
    varname="${entry%%=*}"
    if ! grep -q "^${varname}=" "$VARS_FILE" 2>/dev/null; then
      NEW_VARS+=("$entry"); info "ADD VAR $varname"
    fi
  done
  return 0
}

# Step 6.
add_new_variables() {
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
  return 0
}
