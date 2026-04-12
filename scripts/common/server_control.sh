#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from the common folder
source "$SCRIPT_DIR/load_variables.sh"
source "$SCRIPT_DIR/webhook.sh"

# Reference log file based on loaded variable
LOG_FILE="$SERVER_PATH/logs/latest.log"

# ── Transport detection ──

_use_rcon() {
  [[ "$USE_RCON" == "true" && -n "$RCON_PASSWORD" && "$RCON_PASSWORD" != "none" ]]
}

# ── RCON transport ──

_rcon_send() {
  local cmd="$1"
  # Strip leading / for RCON (RCON doesn't use /)
  cmd="${cmd#/}"
  node "$SCRIPT_DIR/rcon.js" "${RCON_HOST:-localhost}" "${RCON_PORT:-25575}" "$RCON_PASSWORD" "$cmd" 2>/dev/null
}

# ── Screen transport ──

session_running() {
  screen -list 2>/dev/null | grep -q "$INSTANCE_NAME"
}

_screen_send() {
  local command="$1"
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$USER" screen -S "$INSTANCE_NAME" -p 0 -X stuff "$command$(printf \\r)"
  else
    screen -S "$INSTANCE_NAME" -p 0 -X stuff "$command$(printf \\r)"
  fi
}

# ── Server status ──

server_reachable() {
  if _use_rcon; then
    _rcon_send "list" &>/dev/null
    return $?
  else
    session_running
    return $?
  fi
}

# ── Unified command dispatch ──

send_command() {
  local command="$1"

  # Ensure / prefix for screen mode
  if [[ "$command" != /* ]]; then
    command="/$command"
  fi

  if _use_rcon; then
    local response
    response=$(_rcon_send "$command" 2>&1) || {
      echo "[WARN] RCON command failed, falling back to screen..."
      if session_running; then
        _screen_send "$command"
      else
        echo "Screen session '$INSTANCE_NAME' is not running either. Cannot send command."
        return 1
      fi
      return $?
    }
    # Print RCON response if non-empty
    if [[ -n "$response" ]]; then
      echo "$response"
    fi
  else
    if ! session_running; then
      echo "Screen session '$INSTANCE_NAME' is not running. Cannot send command."
      return 1
    fi
    _screen_send "$command"
  fi
}

# ── Convenience functions ──

send_message() {
  local message="$1"
  send_command "/say $message"
}

disable_auto_save() {
  send_command "/save-off"
}

enable_auto_save() {
  send_command "/save-on"
}

read_log() {
  if [ -f "$LOG_FILE" ]; then
    tail -n 10 "$LOG_FILE"
  else
    echo "Log file not found: $LOG_FILE"
    return 1
  fi
}

# Strip the typical Minecraft log prefix from a line
strip_log_prefix() {
  local line="$1"
  if [[ "$line" == *"]: "* ]]; then
    echo "${line##*]: }"
  elif [[ "$line" == *": "* ]]; then
    echo "${line##*: }"
  else
    echo "$line"
  fi
}

# ── Player info ──

get_player_list() {
  if _use_rcon; then
    local response
    response=$(_rcon_send "list" 2>/dev/null) || return 1

    # RCON returns the full response directly
    local player_list
    player_list=$(echo "$response" | sed -n 's/.*players online:\s*\(.*\)/\1/p')
    if [[ -n "$player_list" ]]; then
      echo "$player_list" | sed 's/, */, /g' | sed 's/^ *//;s/ *$//'
    fi
    return 0
  fi

  # Screen fallback
  if ! session_running; then
    echo "Screen session '$INSTANCE_NAME' is not running. Cannot get player list."
    return 1
  fi

  if ! send_command "/list"; then
    echo "Failed to get player list."
    return 1
  fi

  sleep 0.5

  local log_line
  log_line=$(read_log | grep -E "There are [0-9]+(/[0-9]+| of a max of [0-9]+) players online" | tail -n 1)

  if [[ -z "$log_line" ]]; then
    return 0
  fi

  local player_list
  player_list=$(echo "$log_line" | sed -n 's/.*players online:\s*\(.*\)/\1/p')

  if [[ -z "$player_list" ]]; then
    local next_line
    next_line=$(read_log | grep -A1 -F "$log_line" | tail -n 1)
    player_list=$(strip_log_prefix "$next_line")
  fi

  if [[ -n "$player_list" ]]; then
    echo "$player_list" | sed 's/, */, /g' | sed 's/^ *//;s/ *$//'
  fi
}

get_player_count() {
  local player_list
  player_list=$(get_player_list 2>/dev/null)
  if [[ -z "$player_list" ]]; then
    echo 0
  else
    echo "$player_list" | tr ',' '\n' | sed '/^\s*$/d' | wc -l
  fi
}

# ── Save handling ──

wait_for_save_completion() {
  local timeout="${1:-60}"

  if _use_rcon; then
    # RCON: save-all is synchronous, just wait briefly
    sleep 2
    echo "Save completed (RCON)."
    return 0
  fi

  if ! session_running; then
    echo "Screen session '$INSTANCE_NAME' is not running. Cannot wait for save completion."
    return 1
  fi

  echo "Waiting for save to complete (timeout: ${timeout}s)..."

  local save_done=false
  timeout "$timeout" bash -c "
    tail -n 0 -f \"$LOG_FILE\" | while read -r line; do
      if echo \"\$line\" | grep -Eq 'Saved the (game|world)|Saved'; then
        echo 'Save completed.'
        exit 0
      fi
    done
  " && save_done=true

  if ! $save_done; then
    echo "[WARN] Save did not complete within ${timeout}s. Proceeding anyway."
    return 1
  fi
}

save_and_wait() {
  send_message "Saving the server now to ensure no data is lost..."
  send_command "/save-all"
  wait_for_save_completion
}

# ── Countdown ──

countdown() {
  local base_message="$1"
  local start="${2:-5}"
  local end="${3:-1}"

  for ((i=start; i>=end; i--)); do
    local current_announcement="$base_message in §4$i§r seconds!"
    send_message "$current_announcement"
    if [ $i -gt $end ]; then
      sleep 1
    fi
  done
}

# ── Health check ──

wait_for_server_ready() {
  local timeout="${1:-120}"
  local start_time
  start_time=$(date +%s)

  echo "Waiting for server to be ready (timeout: ${timeout}s)..."

  if _use_rcon; then
    # Poll RCON until it responds
    while true; do
      local elapsed=$(( $(date +%s) - start_time ))
      if (( elapsed >= timeout )); then
        echo "[WARN] Server did not respond to RCON within ${timeout}s."
        return 1
      fi
      if _rcon_send "list" &>/dev/null; then
        echo "Server is ready (RCON responding)."
        notify_success "server_start" "Server $INSTANCE_NAME is now online."
        return 0
      fi
      sleep 3
    done
  else
    # Watch log for "Done" message
    if [[ ! -f "$LOG_FILE" ]]; then
      sleep 5
    fi

    local ready=false
    timeout "$timeout" bash -c "
      tail -n 0 -f \"$LOG_FILE\" 2>/dev/null | while read -r line; do
        if echo \"\$line\" | grep -Eq 'Done \\([0-9.]+s\\)'; then
          echo 'Server is ready.'
          exit 0
        fi
      done
    " && ready=true

    if $ready; then
      notify_success "server_start" "Server $INSTANCE_NAME is now online."
      return 0
    else
      echo "[WARN] Server did not report ready within ${timeout}s."
      notify_error "server_start_failed" "Server $INSTANCE_NAME did not start within ${timeout}s."
      return 1
    fi
  fi
}
