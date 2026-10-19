#!/bin/bash
# migrate.sh's use of the server-side migrations: plan (preview) and step 6b.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

plan_server_migrations() {
  # Server-side migrations. After an instance move the files live at the new path.
  if $NEEDS_INSTANCE_MOVE; then SM_INSTANCE_DIR="$_new_instance_dir"; fi
  if $SKIP_SERVER_MIGRATIONS; then
    SM_PENDING=()
  else
    sm_plan
  fi
  return 0
}

# Step 6b. Files the suite wrote for the server itself. None of them restarts it.
apply_server_migrations() {
  if [[ ${#SM_PENDING[@]} -gt 0 ]]; then
    echo; echo -e "${BOLD}Step 6b: Server migrations${NC}"
    # Variables may have moved with the instance; point the migrations at the final path.
    SM_INSTANCE_DIR="$SERVER_PATH"
    SM_DRY_RUN=$DRY_RUN
    SM_MIGRATIONS_OK=true
    sm_apply || SM_MIGRATIONS_OK=false
  fi
  return 0
}
