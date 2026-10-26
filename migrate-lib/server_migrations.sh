#!/bin/bash
# Server-side migrations, run by migrate.sh.
#
# migrate.sh used to bring the helper scripts and shared services up to date and
# nothing else. The server's own files that the suite generated (the instance's
# start.sh, its systemd unit) stayed as installed, so a change to them never
# reached an existing server. Each migration here is one such change.
#
# A migration is three functions, named after its id:
#   sm_<id>_describe   one line for the preview and the list
#   sm_<id>_check      exit 0 when it still has to run; looks at the real files,
#                      so it is idempotent and needs no record to be correct
#   sm_<id>_apply      does it; 0 done, 1 failed, 3 needs a manual step (printed)
#
# What is deliberately not here: the world, mods, server.jar and server.properties.
# Migrations only touch files the suite itself wrote, never the players' data,
# and they never restart the server. Whatever takes effect at the next restart
# says so.
#
# The caller sets (all of them, before sm_plan):
#   SM_SOURCE_ROOT   the minecraft-server-setup checkout
#   SM_INSTANCE_DIR  the instance directory (where the server's files live)
#   SM_INSTANCE_NAME, SM_SCRIPTS_DIR (the deployed scripts dir), SM_DRY_RUN
# and may set SM_UNIT_DIR (default /etc/systemd/system) and SM_SUDO (default
# "sudo -n"; empty means "already allowed to write", for tests).

SERVER_MIGRATIONS=(
  instance_start_script
  unit_start_limits
  cron_to_timers
)

SM_PENDING=()
SM_APPLIED=()
SM_MANUAL=()
SM_FAILED=()
# Set when a migration changed something that only takes effect at the next restart.
SM_NEEDS_RESTART=false

_sm_unit_dir() { echo "${SM_UNIT_DIR:-/etc/systemd/system}"; }
_sm_log_file() { echo "$SM_SCRIPTS_DIR/common/server-migrations.log"; }
_sm_stamp() { date +%Y%m%d-%H%M%S; }

_sm_say() {
  case "$1" in
    ok)   if declare -F log > /dev/null; then log "$2"; else echo "[ok] $2"; fi ;;
    warn) if declare -F warn > /dev/null; then warn "$2"; else echo "[warn] $2" >&2; fi ;;
    info) if declare -F info > /dev/null; then info "$2"; else echo "    $2"; fi ;;
  esac
}

# The id of a migration is recorded with how it ended, for whoever asks later.
sm_record() { # id result
  [[ "${SM_DRY_RUN:-false}" == true ]] && return 0
  mkdir -p "$(dirname "$(_sm_log_file)")"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$(_sm_log_file)"
}

sm_last_result() { # id -> "<time> <result>" or nothing
  [[ -f "$(_sm_log_file)" ]] || return 0
  awk -v id="$1" '$2 == id { last = $1 " " $3 } END { if (last) print last }' "$(_sm_log_file)"
}

# ── instance start.sh ───────────────────────────────────────────────────────

sm_instance_start_script_describe() {
  echo "instance start.sh: lifecycle events and the crash-loop webhook (a copy of the old file is kept; takes effect at the next restart)"
}

sm_instance_start_script_check() {
  local src="$SM_SOURCE_ROOT/src/vanilla/start.sh" dest="$SM_INSTANCE_DIR/start.sh"
  [[ -f "$src" && -f "$dest" ]] && ! cmp -s "$src" "$dest"
}

sm_instance_start_script_apply() {
  local src="$SM_SOURCE_ROOT/src/vanilla/start.sh" dest="$SM_INSTANCE_DIR/start.sh"
  local keep tmp mode
  keep="$dest.pre-migrate-$(_sm_stamp)"
  tmp="$dest.migrate-$$"
  # The running server's bash reads start.sh as it goes, so the file must be
  # replaced, never edited in place: a rename leaves the old inode to the running
  # process and gives the new content to the next start.
  mode="$(stat -c %a "$dest" 2> /dev/null || echo 755)"
  cp -p "$dest" "$keep" || return 1
  cp "$src" "$tmp" || return 1
  chmod "$mode" "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  SM_NEEDS_RESTART=true
  _sm_say info "previous start.sh kept as $(basename "$keep")"
}

# ── systemd unit: crash-loop protection ─────────────────────────────────────
#
# create_service.sh writes StartLimitIntervalSec/Burst/Action, which bound a
# crash loop: five failed starts in two minutes and systemd stops retrying. A
# unit written before that has none, so a broken server restarts forever. Only
# those three lines go in [Unit], where systemd reads them, and any StartLimit*
# found in [Service] (ignored there) is moved; nothing else in a unit the
# operator may have edited is touched, and a unit that already has them in
# [Unit] is left alone.

_sm_unit_file() { echo "$(_sm_unit_dir)/${SM_INSTANCE_NAME}.service"; }

sm_unit_start_limits_describe() {
  echo "systemd unit ${SM_INSTANCE_NAME}.service: crash-loop limits in [Unit], where systemd reads them (StartLimitBurst=5 within 120 s unless set); a daemon-reload, no restart"
}

# StartLimit* lines of one section of a unit file.
_sm_section_limits() { # section unit
  awk -v want="[$1]" '/^\[/ { in_s = ($0 == want) } in_s && /^StartLimit/' "$2"
}

# S-016: systemd reads StartLimitIntervalSec/StartLimitBurst only in [Unit];
# in [Service] they are ignored ("Unknown key name"), so units written with
# them there never stopped a crash loop. Pending while any such line sits in
# [Service], or while [Unit] has none at all.
sm_unit_start_limits_check() {
  local unit
  unit="$(_sm_unit_file)"
  [[ -f "$unit" ]] && grep -q '^\[Service\]' "$unit" && grep -q '^RestartSec=' "$unit" || return 1
  [[ -n "$(_sm_section_limits Service "$unit")" || -z "$(_sm_section_limits Unit "$unit")" ]]
}

sm_unit_start_limits_apply() {
  local unit patched keep dir
  unit="$(_sm_unit_file)"
  dir="$SM_SCRIPTS_DIR/common/migration-backups"
  mkdir -p "$dir" || return 1
  keep="$dir/${SM_INSTANCE_NAME}.service.$(_sm_stamp)"
  patched="$keep.patched"
  cp "$unit" "$keep" || return 1
  # Lines already in [Service] move to [Unit] with their values (they are the
  # operator's, or the ones an earlier setup wrote); defaults only when the
  # unit has none anywhere. Lines already in [Unit] stay as they are.
  local moved existing
  moved="$(_sm_section_limits Service "$unit")"
  existing="$(_sm_section_limits Unit "$unit")"
  if [[ -z "$moved" && -z "$existing" ]]; then
    moved=$'StartLimitIntervalSec=120\nStartLimitBurst=5\nStartLimitAction=none'
  fi
  awk -v add="$moved" '
    /^\[/ { section = $0 }
    section == "[Service]" && /^StartLimit/ { next }
    { print }
    $0 == "[Unit]" && !done && add != "" { print add; done = 1 }
  ' "$unit" > "$patched" || return 1

  local sudo_cmd="${SM_SUDO-sudo -n}"
  # shellcheck disable=SC2086  # SM_SUDO is a command with its own arguments
  if $sudo_cmd tee "$unit" < "$patched" > /dev/null 2>&1; then
    # shellcheck disable=SC2086
    $sudo_cmd systemctl daemon-reload > /dev/null 2>&1 || {
      _sm_say warn "the unit was updated; run: sudo systemctl daemon-reload"
      return 3
    }
    _sm_say info "previous unit kept as $keep"
    return 0
  fi
  _sm_say warn "could not write $unit without a password. Run:"
  _sm_say info "  sudo cp '$patched' '$unit' && sudo systemctl daemon-reload"
  return 3
}

# ── cron to systemd timers ──────────────────────────────────────────────────
#
# Setup used to put the hourly backup (and the scheduled restart) in the server
# owner's crontab. They are systemd timers now (src/setup/management/timer_lib.sh).
# This moves an existing install over: the timers are written and verified
# first, and only then are exactly the suite's cron lines for this instance
# removed. Other crontab lines are never touched, the old crontab is kept, and a
# schedule that is not the suite's own is left for the operator (a manual step)
# instead of being guessed at. The server is not restarted.

_sm_cron_script() { echo "$SM_SCRIPTS_DIR/backup/automation/$1"; }

# The crontab line quoting create_*_job.sh used: printf %q, with % escaped.
_sm_cron_quote() {
  local q
  q="$(printf '%q' "$1")"
  printf '%s\n' "${q//%/\\%}"
}

# Prints the owner's crontab; fails when it cannot be read (no crontab is empty).
_sm_read_crontab() {
  local out rc=0
  out="$(crontab -l 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then printf '%s\n' "$out"; return 0; fi
  printf '%s' "$out" | grep -qi 'no crontab' && return 0
  return 1
}

# The suite's cron line for <script-name> in the crontab text on stdin.
_sm_cron_line_for() {
  local q
  q="$(_sm_cron_quote "$(_sm_cron_script "$1")")"
  grep -F -- "$q" || true
}

_sm_restart_settings() { # prints "enabled interval"
  local vars="$SM_SCRIPTS_DIR/common/variables.txt" enabled interval
  enabled="$(sed -n 's/^RESTART_ENABLED="\(.*\)"$/\1/p' "$vars" 2> /dev/null | tail -n 1)"
  interval="$(sed -n 's/^RESTART_INTERVAL_HOURS="\(.*\)"$/\1/p' "$vars" 2> /dev/null | tail -n 1)"
  echo "${enabled:-false} ${interval:-12}"
}

_sm_timers_usable() {
  [[ -f "$SM_SOURCE_ROOT/src/setup/management/timer_lib.sh" ]] || return 1
  ( SYSTEMD_UNIT_DIR="$(_sm_unit_dir)"; source "$SM_SOURCE_ROOT/src/setup/management/timer_lib.sh"; systemd_usable )
}

sm_cron_to_timers_describe() {
  echo "scheduled jobs: the hourly backup and the scheduled restart move from the crontab to systemd timers (timers are verified before the cron lines are removed; the server is not restarted)"
}

sm_cron_to_timers_check() {
  local tab
  _sm_timers_usable || return 1
  tab="$(_sm_read_crontab 2> /dev/null)" || return 1
  [[ -n "$(printf '%s\n' "$tab" | _sm_cron_line_for run_backup.sh)" || -n "$(printf '%s\n' "$tab" | _sm_cron_line_for scheduled_restart.sh)" ]]
}

# One job: <name> <script-name> <unit-suffix> <expected five cron fields> <calendar> <log>.
# Prints a reason and returns 3 for a schedule that is not the suite's own, 1 on failure.
_sm_move_job() {
  local label="$1" script="$2" suffix="$3" fields="$4" calendar="$5" log="$6" line actual
  line="$(printf '%s\n' "$_SM_TAB" | _sm_cron_line_for "$script" | head -n 1)"
  [[ -n "$line" ]] || return 0
  actual="$(printf '%s\n' "$line" | awk '{ print $1, $2, $3, $4, $5 }')"
  if [[ "$actual" != "$fields" ]]; then
    _sm_say warn "the crontab runs the $label on '$actual', not the suite's '$fields'; it is left in place."
    _sm_say info "  To use a timer, create it with an OnCalendar of your choice (see docs/migrations.md), then delete that cron line."
    return 3
  fi
  (
    local unit_dir; unit_dir="$(_sm_unit_dir)"
    export INSTANCE_NAME="$SM_INSTANCE_NAME" USER="${USER:-$(id -un)}" SYSTEMD_UNIT_DIR="$unit_dir" TIMER_SUDO="${SM_SUDO-sudo -n}"
    source "$SM_SOURCE_ROOT/src/setup/management/timer_lib.sh"
    mkdir -p "$(dirname "$log")"
    timer_install "$suffix" "$label of $INSTANCE_NAME" "$(_sm_cron_script "$script")" "$calendar" "$log" false "$SM_SCRIPTS_DIR" > /dev/null
  ) || return 1
  if ! systemctl is-enabled "${SM_INSTANCE_NAME}-${suffix}.timer" > /dev/null 2>&1; then
    # Not usable: take the units back out so a failed run leaves nothing half-installed.
    (
      local unit_dir; unit_dir="$(_sm_unit_dir)"
      export INSTANCE_NAME="$SM_INSTANCE_NAME" SYSTEMD_UNIT_DIR="$unit_dir" TIMER_SUDO="${SM_SUDO-sudo -n}"
      source "$SM_SOURCE_ROOT/src/setup/management/timer_lib.sh"
      timer_remove "$suffix"
    ) > /dev/null 2>&1 || true
    _sm_say warn "the $suffix timer could not be enabled; the cron line stays."
    return 1
  fi
  _SM_MOVED+=("$script")
  return 0
}

sm_cron_to_timers_apply() {
  local rc=0 enabled interval cal sudo_cmd keep dir remaining
  _SM_MOVED=()
  _SM_TAB="$(_sm_read_crontab)" || { _sm_say warn "the crontab cannot be read; nothing was changed."; return 1; }
  sudo_cmd="${SM_SUDO-sudo -n}"
  # shellcheck disable=SC2086  # SM_SUDO is a command with its own arguments
  if [[ -n "$sudo_cmd" ]] && ! $sudo_cmd true > /dev/null 2>&1; then
    _sm_say warn "writing systemd units needs sudo without a password. As an admin, run:"
    _sm_say info "  bash $SM_SOURCE_ROOT/migrate.sh $SM_SCRIPTS_DIR   (or install the timers by hand, see docs/migrations.md)"
    return 3
  fi

  local manual=false
  _sm_move_job "hourly backup" run_backup.sh backup "20 * * * *" "*-*-* *:20:00" "$SM_SCRIPTS_DIR/backup/logs/backup.log" || { rc=$?; [[ $rc -eq 3 ]] && manual=true || return 1; }

  read -r enabled interval <<< "$(_sm_restart_settings)"
  if [[ -n "$(printf '%s\n' "$_SM_TAB" | _sm_cron_line_for scheduled_restart.sh)" ]]; then
    local fields
    if [[ "$enabled" == true ]] && cal="$(
      source "$SM_SOURCE_ROOT/src/setup/management/timer_lib.sh"; timer_restart_calendar "$interval"
    )"; then
      interval=$((10#$interval))
      if ((interval <= 24)); then fields="0 */$interval * * *"; else fields="0 0 */$((interval / 24)) * *"; fi
      _sm_move_job "scheduled restart" scheduled_restart.sh restart "$fields" "$cal" "$SM_SCRIPTS_DIR/backup/logs/restart.log" || { rc=$?; [[ $rc -eq 3 ]] && manual=true || return 1; }
    else
      _sm_say warn "the crontab has a scheduled restart line but RESTART_ENABLED/RESTART_INTERVAL_HOURS do not describe a valid schedule; it is left in place."
      manual=true
    fi
  fi

  if [[ ${#_SM_MOVED[@]} -gt 0 ]]; then
    dir="$SM_SCRIPTS_DIR/common/migration-backups"
    mkdir -p "$dir" || return 1
    keep="$dir/crontab.$(_sm_stamp)"
    printf '%s\n' "$_SM_TAB" > "$keep" || return 1
    remaining="$_SM_TAB"
    local script q
    for script in "${_SM_MOVED[@]}"; do
      q="$(_sm_cron_quote "$(_sm_cron_script "$script")")"
      remaining="$(printf '%s\n' "$remaining" | grep -vF -- "$q" || true)"
    done
    if [[ -n "${remaining//[[:space:]]/}" ]]; then
      printf '%s\n' "$remaining" | crontab - || { crontab "$keep" 2> /dev/null; return 1; }
    else
      crontab -r 2> /dev/null || true
    fi
    for script in "${_SM_MOVED[@]}"; do
      if _sm_read_crontab | _sm_cron_line_for "$script" | grep -q .; then
        crontab "$keep" 2> /dev/null
        _sm_say warn "the cron line for $script is still there after the edit; the old crontab was put back."
        return 1
      fi
    done
    _sm_say info "previous crontab kept as $keep"
  fi

  [[ "$manual" == true ]] && return 3
  return 0
}

# ── runner ──────────────────────────────────────────────────────────────────

# Fills SM_PENDING with the ids that still have to run and prints one line each.
sm_plan() {
  SM_PENDING=()
  local id
  for id in "${SERVER_MIGRATIONS[@]}"; do
    if "sm_${id}_check"; then
      SM_PENDING+=("$id")
      _sm_say info "SERVER  $("sm_${id}_describe")"
    fi
  done
}

# Runs the pending migrations. One that fails or needs a manual step does not
# stop the others; the outcome of each is recorded and returned in the arrays.
sm_apply() {
  SM_APPLIED=(); SM_MANUAL=(); SM_FAILED=()
  local id rc
  for id in "${SM_PENDING[@]}"; do
    if [[ "${SM_DRY_RUN:-false}" == true ]]; then
      echo "[DRY-RUN] server migration: $id"
      continue
    fi
    rc=0
    "sm_${id}_apply" || rc=$?
    case "$rc" in
      0) SM_APPLIED+=("$id"); sm_record "$id" applied; _sm_say ok "$("sm_${id}_describe")" ;;
      3) SM_MANUAL+=("$id");  sm_record "$id" manual;  _sm_say warn "$id needs a manual step (above)" ;;
      *) SM_FAILED+=("$id");  sm_record "$id" failed;  _sm_say warn "$id failed; it will be tried again on the next migration" ;;
    esac
  done
  [[ ${#SM_FAILED[@]} -eq 0 ]]
}

# One line per migration: current or pending, and what the log says about it.
sm_list() {
  local id state last
  for id in "${SERVER_MIGRATIONS[@]}"; do
    if "sm_${id}_check"; then state="pending"; else state="current"; fi
    last="$(sm_last_result "$id")"
    printf '%-24s %-8s %s%s\n' "$id" "$state" "$("sm_${id}_describe")" "${last:+  (last: $last)}"
  done
}
