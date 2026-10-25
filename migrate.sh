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
# ║    - Cron lines other than the suite's own (those move to   ║
# ║      systemd timers, see the migrations below)              ║
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
# ║  Applies the server-side migrations (migrate-lib/):         ║
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
MIGRATE_LIB="$MIGRATE_SCRIPT_DIR/migrate-lib"

if [[ ! -d "$MIGRATE_LIB" ]]; then
  echo "migrate-lib/ not found next to migrate.sh: $MIGRATE_LIB" >&2
  echo "Run this script from a complete minecraft-server-setup checkout." >&2
  exit 1
fi

# The modules define functions and constants only; the phases run below, in
# order. ui.sh comes first because the others call log/warn/err/info.
# shellcheck source=migrate-lib/ui.sh
source "$MIGRATE_LIB/ui.sh"
# shellcheck source=migrate-lib/cli.sh
source "$MIGRATE_LIB/cli.sh"
# shellcheck source=migrate-lib/context.sh
source "$MIGRATE_LIB/context.sh"
# shellcheck source=migrate-lib/server_migrations.sh
source "$MIGRATE_LIB/server_migrations.sh"
# shellcheck source=migrate-lib/server_migration_steps.sh
source "$MIGRATE_LIB/server_migration_steps.sh"
# shellcheck source=migrate-lib/preflight.sh
source "$MIGRATE_LIB/preflight.sh"
# shellcheck source=migrate-lib/json_config.sh
source "$MIGRATE_LIB/json_config.sh"
# shellcheck source=migrate-lib/npm.sh
source "$MIGRATE_LIB/npm.sh"
# shellcheck source=migrate-lib/plan_scripts.sh
source "$MIGRATE_LIB/plan_scripts.sh"
# shellcheck source=migrate-lib/api_wrapper.sh
source "$MIGRATE_LIB/api_wrapper.sh"
# shellcheck source=migrate-lib/variables.sh
source "$MIGRATE_LIB/variables.sh"
# shellcheck source=migrate-lib/structure.sh
source "$MIGRATE_LIB/structure.sh"
# shellcheck source=migrate-lib/plan.sh
source "$MIGRATE_LIB/plan.sh"
# shellcheck source=migrate-lib/locks.sh
source "$MIGRATE_LIB/locks.sh"
# shellcheck source=migrate-lib/backup.sh
source "$MIGRATE_LIB/backup.sh"
# shellcheck source=migrate-lib/recovery.sh
source "$MIGRATE_LIB/recovery.sh"
# shellcheck source=migrate-lib/server_lifecycle.sh
source "$MIGRATE_LIB/server_lifecycle.sh"
# shellcheck source=migrate-lib/replace_scripts.sh
source "$MIGRATE_LIB/replace_scripts.sh"
# shellcheck source=migrate-lib/verify.sh
source "$MIGRATE_LIB/verify.sh"
# shellcheck source=migrate-lib/report.sh
source "$MIGRATE_LIB/report.sh"

# ── Inputs ──
parse_args "$@"
validate_target
init_server_migration_inputs

if $LIST_SERVER_MIGRATIONS; then
  sm_list
  exit 0
fi

init_api_state
print_banner
run_preflight_checks

# ── Plan: nothing is changed until the confirmation ──
plan_instance_scripts
plan_api_wrapper
plan_new_variables
detect_structure
plan_server_migrations
compute_scope
exit_if_nothing_to_do
print_plan_summary
confirm_plan

# ── Apply ──
if $NEEDS_INSTANCE_UPDATE && ! $DRY_RUN; then
  acquire_migration_locks
fi
create_backup
install_recovery_trap
stop_server
apply_structural_migration
run_replace_scripts
update_api_wrapper
add_new_variables
apply_server_migrations
install_instance_npm_deps
verify_migration
_MIGRATE_DONE=true
prune_old_migration_archives
restart_server
restart_api_wrapper
print_completion_report
