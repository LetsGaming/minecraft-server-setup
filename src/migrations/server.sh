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
# those three lines are added, after RestartSec; nothing else in a unit the
# operator may have edited is touched, and a unit that already sets any
# StartLimit* is left alone.

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
