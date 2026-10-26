#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides,
# using a private name so we don't overwrite the caller's SCRIPT_DIR.
_SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from the common folder
source "$_SC_DIR/load_variables.sh"
source "$_SC_DIR/webhook.sh"

# Reference log file based on loaded variable
LOG_FILE="$SERVER_PATH/logs/latest.log"

# ── Transport detection ──

_use_rcon() {
  [[ "$USE_RCON" == "true" && -n "$RCON_PASSWORD" && "$RCON_PASSWORD" != "none" ]]
}

# ── RCON transport ──

# _rcon_send_timeout <timeout-ms|""> <command>
# An empty timeout keeps rcon.js's default.
_rcon_send_timeout() {
  local timeout_ms="$1" cmd="$2"
  local opts=()
  # Strip leading / for RCON (RCON doesn't use /)
  cmd="${cmd#/}"
  [[ -n "$timeout_ms" ]] && opts+=("--timeout-ms=$timeout_ms")
  # Pass the password via the environment, not as an argv element: argv is
  # world-readable through `ps` / /proc/<pid>/cmdline.
  RCON_PASSWORD="$RCON_PASSWORD" \
    node "$_SC_DIR/rcon.js" "${opts[@]}" "${RCON_HOST:-localhost}" "${RCON_PORT:-25575}" "$cmd" 2>/dev/null
}

_rcon_send() {
  _rcon_send_timeout "" "$1"
}

# ── Screen transport ──

# Anchored to `<pid>.<name><whitespace>`: a bare substring match would treat a
# running "mc2" session as "mc".
session_running() {
  local name_re
  name_re=$(printf '%s' "$INSTANCE_NAME" | sed 's/[][\.*^$(){}+?|]/\\&/g')
  screen -list 2>/dev/null | grep -Eq "^[[:space:]]*[0-9]+\.${name_re}[[:space:]]"
}

# _screen_escape <text>: one console line, safe for `screen -X stuff`.
# Control characters are dropped (a CR or LF would type a second command),
# and \ ^ $ are escaped: stuff turns ^M and \015 into Enter and expands
# $VAR, so text like "hi^Mop Mallory" ran a second command (S-026, the
# wrapper's W-001).
_screen_escape() {
  local s="${1//[[:cntrl:]]/}"
  s="${s//\\/\\\\}"
  s="${s//^/\\^}"
  s="${s//\$/\\\$}"
  printf '%s' "$s"
}

_screen_send() {
  local command
  command="$(_screen_escape "$1")"
  if [ "$(id -u)" -eq 0 ]; then
    sudo -n -u "$USER" screen -S "$INSTANCE_NAME" -p 0 -X stuff "$command$(printf \\r)"
  else
    screen -S "$INSTANCE_NAME" -p 0 -X stuff "$command$(printf \\r)"
  fi
}

# ── Systemctl wrapper (passwordless sudo) ──

systemctl_cmd() {
  local action="$1"
  local service="${INSTANCE_NAME}.service"
  local extra_args=("${@:2}")
  local output

  # A crash-looping server trips StartLimitBurst (see create_service.sh) and
  # the unit lands in `failed` — systemd then refuses any further start until
  # reset-failed clears it. Without this, restart/start from the dashboard
  # would keep failing even after the underlying cause (e.g. a bad mod) is
  # fixed, with no way to recover short of SSH. Best-effort and silent: a
  # healthy unit has nothing to reset, and a sudoers gap here must not block
  # the actual start/restart from at least being attempted.
  if [[ "$action" == "start" || "$action" == "restart" ]]; then
    sudo -n systemctl reset-failed "$service" >/dev/null 2>&1 || true
  fi

  if ! output=$(sudo -n systemctl "$action" "${extra_args[@]}" "$service" 2>&1); then
    if echo "$output" | grep -qiE "password is required|not in the sudoers|authentication failure|a terminal is required"; then
      echo "[SUDO ERROR] Passwordless sudo is not configured for 'systemctl $action $service'." >&2
      echo "[SUDO ERROR] Required sudoers rule:" >&2
      echo "[SUDO ERROR]   $USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start $service, /usr/bin/systemctl stop $service, /usr/bin/systemctl restart $service, /usr/bin/systemctl enable $service, /usr/bin/systemctl reset-failed $service" >&2
      echo "[SUDO ERROR] See docs/sudoers-setup.md for full instructions." >&2
      return 1
    fi
    # Not a sudo error — propagate the original output and fail
    echo "$output" >&2
    return 1
  fi

  if [[ -n "$output" ]]; then
    echo "$output"
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

# send_command_strict <command> [rcon-timeout-ms]
# For commands whose success matters (the save commands): an RCON error or
# timeout is a failure, and the command is not typed into the console a second
# time, which would queue a second save behind a slow first one.
send_command_strict() {
  local command="$1" timeout_ms="${2:-}"

  if [[ "$command" != /* ]]; then
    command="/$command"
  fi

  if _use_rcon; then
    local response
    response=$(_rcon_send_timeout "$timeout_ms" "$command" 2>&1) || {
      echo "[ERROR] RCON did not confirm: $command" >&2
      return 1
    }
    if [[ -n "$response" ]]; then
      echo "$response"
    fi
    return 0
  fi

  if ! session_running; then
    echo "Screen session '$INSTANCE_NAME' is not running. Cannot send command."
    return 1
  fi
  _screen_send "$command"
}

# ── Convenience functions ──

send_message() {
  local message="$1"
  send_command "/say $message"
}

disable_auto_save() {
  send_command_strict "/save-off"
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

# The server's own answer to /list in the log: its bracketed tags, then the
# sentence at the start of the message (Minecraft 26.3 puts "System chat: " in
# front of it). A chat line starts with <name> and /say with [Server], so
# neither can pass for it.
_LIST_REPLY_RE='^\[[0-9:]+\] \[[^]/]+/INFO\]: (System chat: )?There are [0-9]+(/| of a max of )[0-9]+ players online'

# _list_reply_since <byte-offset>
# The last /list answer written to the log after the offset, if any.
_list_reply_since() {
  local offset="$1" size
  [[ -f "$LOG_FILE" ]] || return 0
  size=$(_log_size)
  (( size < offset )) && offset=0
  tail -c +"$((offset + 1))" "$LOG_FILE" 2>/dev/null | grep -E "$_LIST_REPLY_RE" | tail -n 1 || true
}

# _query_players
# Prints "<count><TAB><names>". Fails when the server's answer could not be
# read: callers must treat that as "players may be online", never as zero.
_query_players() {
  local line="" offset i
  local re='There are ([0-9]+)(/| of a max of )[0-9]+ players online:?[[:space:]]*(.*)$'

  if _use_rcon; then
    line=$(_rcon_send "list") || return 1
  else
    session_running || return 1
    offset=$(_log_size)
    send_command "/list" > /dev/null || return 1
    # Read from the offset recorded before the command, so an older answer
    # or a slow reply is not mistaken for this one.
    for ((i = 0; i < 20; i++)); do
      sleep 0.5
      line=$(_list_reply_since "$offset")
      [[ -n "$line" ]] && break
    done
  fi

  [[ -n "$line" && "$line" =~ $re ]] || return 1
  local names="${BASH_REMATCH[3]}"
  names=$(echo "$names" | sed 's/, */, /g;s/^ *//;s/ *$//')
  printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$names"
}

# Prints the names of the players online, comma separated; nothing when none.
# Fails when the server could not be asked.
get_player_list() {
  local info
  info=$(_query_players) || return 1
  local names="${info#*$'\t'}"
  [[ -n "$names" ]] && echo "$names"
  return 0
}

# Prints the number of players online. Fails when the server could not be asked.
get_player_count() {
  local info
  info=$(_query_players) || return 1
  echo "${info%%$'\t'*}"
}

# ── Save handling ──

# Size of the server log in bytes, 0 when it does not exist yet.
_log_size() {
  if [[ -f "$LOG_FILE" ]]; then
    wc -c < "$LOG_FILE" | tr -d '[:space:]'
  else
    echo 0
  fi
}

# _log_has_since <byte-offset> <extended-regex>
# True when the log has a line matching the pattern written after the offset.
# A log that is now shorter than the offset was rotated, so it is read whole.
_log_has_since() {
  local offset="$1" pattern="$2" size
  [[ -f "$LOG_FILE" ]] || return 1
  size=$(_log_size)
  (( size < offset )) && offset=0
  tail -c +"$((offset + 1))" "$LOG_FILE" 2>/dev/null | grep -Eq "$pattern"
}

SAVE_TIMEOUT_SECONDS="${SAVE_TIMEOUT_SECONDS:-120}"

# The server's own "Saved the game" line, anchored at both ends (timestamp and
# thread included) so a player typing the phrase, even with a fake prefix, cannot
# match. Minecraft 26.3 logs it as "System chat: Saved the game" (and
# "System chat: [Rcon: Saved the game]" for an RCON command); older versions log
# it bare after "INFO]: ".
SAVED_LINE_RE='^[[][0-9:]+[]] [[]Server thread/INFO[]]: (System chat: )?([[]Rcon: )?Saved the (game|world)[]]?[[:space:]]*$'

# wait_for_save_completion [timeout-seconds] [log-offset]
# The offset must be taken BEFORE the save command is sent (see save_and_wait);
# a save that finishes quickly would otherwise be written before the wait
# begins and never be seen.
# shellcheck disable=SC2120  # arguments are optional; callers use the defaults
wait_for_save_completion() {
  local timeout="${1:-60}"
  local offset="${2:-}"

  if _use_rcon; then
    # save-all flush answers over RCON only once it has finished, so the
    # command's own confirmation (see save_and_wait) is the completion signal.
    echo "Save completed (RCON)."
    return 0
  fi

  if ! session_running; then
    echo "Screen session '$INSTANCE_NAME' is not running. Cannot wait for save completion."
    return 1
  fi

  [[ -n "$offset" ]] || offset=$(_log_size)

  echo "Waiting for save to complete (timeout: ${timeout}s)..."

  local waited
  for ((waited = 0; waited < timeout; waited++)); do
    # The server's own line only (S-009): the old bare "Saved" also matched
    # any player who typed the word in chat.
    if _log_has_since "$offset" "$SAVED_LINE_RE"; then
      echo "Save completed."
      return 0
    fi
    sleep 1
  done

  echo "[WARN] Save did not complete within ${timeout}s. Proceeding anyway."
  return 1
}

save_and_wait() {
  local offset
  offset=$(_log_size)
  send_message "Saving the server now to ensure no data is lost..." || true
  # flush (S-009): without it, 1.17+ logs "Saved the game" while chunk
  # writes are still queued, and a backup can copy torn region files. On a big
  # or modded world the flush takes longer than rcon.js's default timeout, so
  # it gets SAVE_TIMEOUT_SECONDS, and a timeout is a failed save.
  if ! send_command_strict "/save-all flush" "$((SAVE_TIMEOUT_SECONDS * 1000))"; then
    echo "[ERROR] The server did not confirm the save." >&2
    return 1
  fi
  wait_for_save_completion "$SAVE_TIMEOUT_SECONDS" "$offset"
}

# ── Countdown ──

countdown() {
  local base_message="$1"
  local start="${2:-5}"
  local end="${3:-1}"
  local i

  for ((i=start; i>=end; i--)); do
    local current_announcement="$base_message in §4$i§r seconds!"
    send_message "$current_announcement"
    if [ "$i" -gt "$end" ]; then
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
    # Watch the log for the "Done" message
    if [[ ! -f "$LOG_FILE" ]]; then
      sleep 5
    fi

    local offset ready=false waited
    offset=$(_log_size)
    for ((waited = 0; waited < timeout; waited++)); do
      if _log_has_since "$offset" 'Done \([0-9.]+s\)'; then
        echo "Server is ready."
        ready=true
        break
      fi
      sleep 1
    done

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
