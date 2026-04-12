#!/bin/bash
set -e

# Multi-instance management wrapper
# Usage: manage.sh <command> [instance] [args...]
#
# Commands:
#   status              Show status of all instances
#   start <instance>    Start a specific instance
#   stop <instance>     Stop a specific instance
#   restart <instance>  Restart a specific instance
#   backup <instance>   Run backup for a specific instance
#   list                List all configured instances

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect instances by looking for scripts/<name>/common/variables.txt
find_instances() {
  local base_dir
  base_dir=$(dirname "$SCRIPT_DIR")

  if [[ -d "$base_dir/scripts" ]]; then
    for dir in "$base_dir"/scripts/*/; do
      local vars_file="$dir/common/variables.txt"
      if [[ -f "$vars_file" ]]; then
        basename "$dir"
      fi
    done
  fi
}

get_instance_scripts_dir() {
  local instance="$1"
  local base_dir
  base_dir=$(dirname "$SCRIPT_DIR")
  echo "$base_dir/scripts/$instance"
}

print_help() {
  cat <<EOF
Minecraft Server Multi-Instance Manager

Usage: $0 <command> [instance] [args...]

Commands:
  list                List all configured instances
  status [instance]   Show status (all or specific instance)
  start <instance>    Start a specific instance
  stop <instance>     Stop a specific instance (graceful)
  restart <instance>  Restart a specific instance (player-aware)
  backup <instance>   Run backup for a specific instance
  update <instance>   Check for updates for a specific instance

Examples:
  $0 list
  $0 status
  $0 restart survival
  $0 backup creative
EOF
}

cmd_list() {
  echo "Configured instances:"
  local instances
  instances=$(find_instances)
  if [[ -z "$instances" ]]; then
    echo "  (none found)"
    return
  fi
  for instance in $instances; do
    local scripts_dir
    scripts_dir=$(get_instance_scripts_dir "$instance")
    local server_path
    server_path=$(grep '^SERVER_PATH=' "$scripts_dir/common/variables.txt" 2>/dev/null | head -1 | cut -d'"' -f2)
    echo "  $instance  →  $server_path"
  done
}

cmd_status() {
  local target="$1"
  local instances
  if [[ -n "$target" ]]; then
    instances="$target"
  else
    instances=$(find_instances)
  fi

  if [[ -z "$instances" ]]; then
    echo "No instances found."
    return
  fi

  printf "%-20s %-12s %-10s\n" "INSTANCE" "STATUS" "PLAYERS"
  printf "%-20s %-12s %-10s\n" "--------" "------" "-------"

  for instance in $instances; do
    local scripts_dir
    scripts_dir=$(get_instance_scripts_dir "$instance")

    if [[ ! -f "$scripts_dir/common/variables.txt" ]]; then
      printf "%-20s %-12s %-10s\n" "$instance" "NOT FOUND" "-"
      continue
    fi

    local status="Stopped"
    local players="-"

    if screen -list 2>/dev/null | grep -q "$instance"; then
      status="Running"
      # Try to get player count
      players=$(bash "$scripts_dir/misc/status.sh" 2>/dev/null | grep -oP 'Player List: \K.*' || echo "?")
      if [[ -z "$players" || "$players" == "No players online." ]]; then
        players="0"
      fi
    elif systemctl is-active "$instance.service" &>/dev/null; then
      status="Running"
    fi

    printf "%-20s %-12s %-10s\n" "$instance" "$status" "$players"
  done
}

require_instance() {
  local instance="$1"
  if [[ -z "$instance" ]]; then
    echo "[ERROR] Instance name required."
    echo "Use '$0 list' to see available instances."
    exit 1
  fi

  local scripts_dir
  scripts_dir=$(get_instance_scripts_dir "$instance")
  if [[ ! -f "$scripts_dir/common/variables.txt" ]]; then
    echo "[ERROR] Instance '$instance' not found."
    echo "Use '$0 list' to see available instances."
    exit 1
  fi
}

# ── Main ──

COMMAND="${1:-help}"
INSTANCE="${2:-}"
shift 2 2>/dev/null || true

case "$COMMAND" in
  list)
    cmd_list
    ;;
  status)
    cmd_status "$INSTANCE"
    ;;
  start)
    require_instance "$INSTANCE"
    bash "$(get_instance_scripts_dir "$INSTANCE")/start.sh"
    ;;
  stop)
    require_instance "$INSTANCE"
    bash "$(get_instance_scripts_dir "$INSTANCE")/shutdown.sh"
    ;;
  restart)
    require_instance "$INSTANCE"
    bash "$(get_instance_scripts_dir "$INSTANCE")/smart_restart.sh" "$@"
    ;;
  backup)
    require_instance "$INSTANCE"
    bash "$(get_instance_scripts_dir "$INSTANCE")/backup/backup.sh" "$@"
    ;;
  update)
    require_instance "$INSTANCE"
    node "$(get_instance_scripts_dir "$INSTANCE")/update/check-updates.js" "$@"
    ;;
  help|--help|-h)
    print_help
    ;;
  *)
    echo "[ERROR] Unknown command: $COMMAND"
    print_help
    exit 1
    ;;
esac
