#!/bin/bash
# Command line: flag defaults, --help text and argument parsing.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# ── Args ──
TARGET_SCRIPTS_DIR=""
SKIP_CONFIRM=false
SKIP_STOP=false
RESTART_SERVER=false
SKIP_SERVICE_RESTART=false
DRY_RUN=false
SKIP_SERVER_MIGRATIONS=false
LIST_SERVER_MIGRATIONS=false

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
  - The folder is swapped as a whole, so ACLs set by service_user.sh are lost:
    the summary prints the command that grants them again
  - Each run leaves a <scripts>_backup_<stamp> archive; after a successful run
    only the newest 5 are kept (MIGRATE_KEEP_ARCHIVES=N changes that, 0 keeps all)

Server-side migrations (migrate-lib/server_migrations.sh):
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
  - Cron lines other than the suite's own backup and restart jobs (those move to
    systemd timers), and systemd units beyond the server-side migrations above
EOF
}

parse_args() {
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
  return 0
}
