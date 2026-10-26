#!/bin/bash
# Helpers that install the suite's scheduled jobs as systemd timers. Source it.
# They replace the crontab lines of create_backup_job.sh and
# create_restart_job.sh on hosts where systemd is running; cron_lib.sh stays for
# hosts without it.
#
# Units are written as the SEC-03 pattern of create_service.sh does: streamed to
# `sudo tee` on stdin, never staged in /tmp. They run as the server owner and
# carry none of the sandboxing options (NoNewPrivileges, PrivateTmp,
# ProtectSystem): the jobs call `sudo -n systemctl` and talk to screen's sockets
# under /run/screen, which those options break.
#
# Overrides, mainly for the tests:
#   SYSTEMD_UNIT_DIR   where units go (default /etc/systemd/system)
#   TIMER_SUDO         privilege prefix (default "sudo"; empty when already root)
#   SYSTEMD_USABLE     true or false forces the answer of systemd_usable

: "${SYSTEMD_UNIT_DIR:=/etc/systemd/system}"
# Arrays the caller sets before sourcing (or calling) must survive being sourced.
[[ -v TIMER_EXEC_ARGS ]] || TIMER_EXEC_ARGS=()
[[ -v TIMER_STOPPOST_ARGS ]] || TIMER_STOPPOST_ARGS=()

# systemd_usable: true when systemd is the running init and systemctl exists.
# Containers and WSL without systemd are not, and keep using cron.
systemd_usable() {
  case "${SYSTEMD_USABLE:-}" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  [[ -d /run/systemd/system ]] && command -v systemctl > /dev/null 2>&1
}

_timer_sudo() {
  if [[ -v TIMER_SUDO ]]; then
    # shellcheck disable=SC2086  # the prefix is a command line on purpose
    $TIMER_SUDO "$@"
  else
    sudo "$@"
  fi
}

# timer_quote <string>: one systemd word. Double quotes group it; backslash and
# the double quote are escaped, and % and $ are doubled because systemd expands
# specifiers and environment variables in command lines. A newline would end
# the line, so it is refused.
timer_quote() {
  local s="$1"
  if [[ "$s" == *$'\n'* ]]; then
    echo "A newline cannot go into a systemd unit: $s" >&2
    return 1
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//%/%%}"
  s="${s//\$/\$\$}"
  printf '"%s"' "$s"
}

# timer_unit_name <suffix>: the unit base name for this instance, e.g.
# "survival-backup". Needs INSTANCE_NAME.
timer_unit_name() {
  printf '%s-%s\n' "${INSTANCE_NAME:?INSTANCE_NAME not set}" "$1"
}

# timer_restart_calendar <hours>: the OnCalendar value for a restart every N
# hours, with the rule create_restart_job.sh and loadVariables.js already
# apply: N divides 24 (the count restarts at midnight) or is a multiple of 24.
# Prints nothing and fails otherwise.
timer_restart_calendar() {
  local n="$1"
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
  esac
  n=$((10#$n))
  if ((n >= 1 && n <= 24 && 24 % n == 0)); then
    if ((n == 24)); then
      echo '*-*-* 00:00:00'
    else
      printf '*-*-* 00/%d:00:00\n' "$n"
    fi
  elif ((n > 24 && n % 24 == 0)); then
    printf '*-*-1/%d 00:00:00\n' $((n / 24))
  else
    return 1
  fi
}

# _timer_exec_line <log> <script> [args...]: `/usr/bin/bash -c` wrapper that opens
# the log as the server user and then runs the script with its arguments.
# ($$ is a literal $ for systemd; $0 is the log, "$@" the script and its arguments.)
_timer_exec_line() {
  local log="$1" word line
  shift
  line="/usr/bin/bash -c 'exec >>\"\$\$0\" 2>&1; exec /usr/bin/bash \"\$\$@\"' $(timer_quote "$log")"
  for word in "$@"; do line+=" $(timer_quote "$word")"; done
  printf '%s' "$line"
}

# timer_render_service <description> <script> <logfile> [<working-dir>]
# The oneshot service the timer starts. Output is appended to the log file the
# cron line used (O_APPEND keeps the copy-truncate rotation of run_backup.sh
# safe). TimeoutStartSec is a ceiling only; the scripts have their own timeouts.
# TIMER_EXEC_ARGS (an array) holds extra arguments for the script and
# TIMER_STOPPOST_ARGS (script first) an optional ExecStopPost; both are read from
# the caller's shell and default to none.
timer_render_service() {
  local desc="$1" script="$2" log="$3" workdir="${4:-}" node_dir path_value
  node_dir="$(dirname "$(command -v node 2> /dev/null || echo /usr/bin/node)")"
  path_value="$node_dir:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  {
    echo "[Unit]"
    echo "Description=$desc"
    echo
    echo "[Service]"
    echo "Type=oneshot"
    echo "User=${USER:?USER not set}"
    echo "Group=$USER"
    [[ -n "$workdir" ]] && echo "WorkingDirectory=$workdir"
    echo "Environment=$(timer_quote "PATH=$path_value")"
    # The log is opened by this shell after systemd has dropped to User=, never by
    # systemd itself: StandardOutput=append: is opened as root, so a symlink the
    # server user planted in its own logs folder would make root append to any
    # file. ($$ is a literal $ for systemd; $0 and $1 are the log and the script.)
    echo "ExecStart=$(_timer_exec_line "$log" "$script" "${TIMER_EXEC_ARGS[@]}")"
    if ((${#TIMER_STOPPOST_ARGS[@]} > 0)); then
      echo "ExecStopPost=$(_timer_exec_line "$log" "${TIMER_STOPPOST_ARGS[@]}")"
    fi
    echo "TimeoutStartSec=3h"
  }
}

# timer_render_timer <description> <calendar> [<persistent: true|false>] [<random-delay-sec>]
timer_render_timer() {
  local desc="$1" calendar="$2" persistent="${3:-false}" delay="${4:-0}"
  {
    echo "[Unit]"
    echo "Description=$desc"
    echo
    echo "[Timer]"
    echo "OnCalendar=$calendar"
    echo "Persistent=$persistent"
    ((delay > 0)) && echo "RandomizedDelaySec=${delay}s"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  }
}

# _timer_write_if_changed <path> (content on stdin): writes only when it differs,
# and prints "changed" or "same".
_timer_write_if_changed() {
  local path="$1" new current
  new="$(cat)"
  # shellcheck disable=SC2024  # the current content is read as ourselves on purpose
  current="$(_timer_sudo cat "$path" 2> /dev/null || true)"
  if [[ "$current" == "$new" ]]; then
    echo same
    return 0
  fi
  printf '%s\n' "$new" | _timer_sudo tee "$path" > /dev/null
  _timer_sudo chmod 644 "$path"
  echo changed
}

# timer_install <suffix> <description> <script> <calendar> <logfile> [persistent] [workdir] [random-delay-sec]
# Writes <instance>-<suffix>.service and .timer, reloads systemd and enables the
# timer. Safe to run again: unchanged units are left alone.
timer_install() {
  local suffix="$1" desc="$2" script="$3" calendar="$4" log="$5" persistent="${6:-false}" workdir="${7:-}" delay="${8:-0}"
  local name state_s state_t
  name="$(timer_unit_name "$suffix")" || return 1
  state_s="$(timer_render_service "$desc" "$script" "$log" "$workdir" | _timer_write_if_changed "$SYSTEMD_UNIT_DIR/$name.service")" || return 1
  state_t="$(timer_render_timer "$desc" "$calendar" "$persistent" "$delay" | _timer_write_if_changed "$SYSTEMD_UNIT_DIR/$name.timer")" || return 1
  if [[ "$state_s" == changed || "$state_t" == changed ]]; then
    _timer_sudo systemctl daemon-reload || return 1
  fi
  _timer_sudo systemctl enable --now "$name.timer" > /dev/null 2>&1 || {
    echo "Could not enable $name.timer" >&2
    return 1
  }
  echo "Timer $name.timer is enabled ($calendar)."
}

# timer_remove <suffix>: stops and removes both units. Missing units are fine.
timer_remove() {
  local name removed=false ext
  name="$(timer_unit_name "$1")" || return 1
  for ext in timer service; do
    if [[ -e "$SYSTEMD_UNIT_DIR/$name.$ext" ]]; then
      _timer_sudo systemctl stop "$name.$ext" 2> /dev/null || true
      _timer_sudo systemctl disable "$name.$ext" 2> /dev/null || true
      _timer_sudo rm -f "$SYSTEMD_UNIT_DIR/$name.$ext"
      removed=true
    fi
  done
  [[ "$removed" == true ]] && { _timer_sudo systemctl daemon-reload 2> /dev/null || true; }
  return 0
}
