#!/bin/bash
# Read-only health check of one installed instance. Meant for an admin with
# sudo: `bash manage.sh doctor [instance] [--test-webhook]`.
#
# One line per check: OK, WARN, FAIL or SKIP. The exit status is 1 when any
# check failed; warnings and skips do not fail the run.
#   --test-webhook   also send one `webhook_test` notification and report
#                    whether the endpoint accepted it (sends nothing otherwise)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPTS_DIR/common/load_variables.sh"
source "$SCRIPTS_DIR/common/webhook.sh"
set +e

TEST_WEBHOOK=false
for arg in "$@"; do
  case "$arg" in
    --test-webhook) TEST_WEBHOOK=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

N_OK=0 N_WARN=0 N_FAIL=0 N_SKIP=0
report() { # level name detail
  case "$1" in
    OK) N_OK=$((N_OK + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
  esac
  printf '[%s] %s: %s\n' "$1" "$2" "$3"
}

# elevated <command...>: run through sudo without ever prompting.
elevated() {
  if [[ "$(id -u)" == 0 ]]; then "$@"; else sudo -n "$@"; fi
}

UNIT="$INSTANCE_NAME.service"

check_service() {
  if ! command -v systemctl > /dev/null 2>&1; then
    report SKIP service "systemctl not found"
    return
  fi
  local enabled active
  enabled="$(systemctl is-enabled "$UNIT" 2> /dev/null)" || true
  active="$(systemctl is-active "$UNIT" 2> /dev/null)" || true
  if [[ "$enabled" == enabled ]]; then
    report OK service "$UNIT is enabled"
  else
    report WARN service "$UNIT is ${enabled:-not installed}; it will not start at boot"
  fi
  if [[ "$active" == active ]]; then
    report OK service "$UNIT is running"
  else
    report WARN service "$UNIT is ${active:-not running}"
  fi

  # systemd reads StartLimit* only in [Unit]; the same rule migrate.sh applies.
  local limits
  limits="$(systemctl cat "$UNIT" 2> /dev/null | awk '/^\[/ { in_unit = ($0 == "[Unit]") } in_unit && /^StartLimit/')"
  if [[ -n "$limits" ]]; then
    report OK crash-loop-limits "the unit stops retrying a crashing server"
  else
    report WARN crash-loop-limits "the unit has no StartLimit* lines in [Unit]; run migrate.sh"
  fi
}

# The scheduled jobs run from systemd timers (<instance>-backup.timer and
# <instance>-restart.timer); hosts without systemd use cron lines instead. A job
# that has both would run twice, which is worth a warning.
CRON_TAB=""
CRON_TAB_READABLE=false
read_cron_tab() {
  local rc=0
  command -v crontab > /dev/null 2>&1 || return 0
  if [[ "$(id -un)" == "$USER" ]]; then
    CRON_TAB="$(crontab -l 2>&1)" || rc=$?
  else
    CRON_TAB="$(sudo -n crontab -u "$USER" -l 2>&1)" || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    if printf '%s' "$CRON_TAB" | grep -qi 'no crontab'; then
      CRON_TAB=""
    else
      CRON_TAB=""
      return 0
    fi
  fi
  CRON_TAB_READABLE=true
}

timer_enabled() { [[ "$(systemctl is-enabled "$1" 2> /dev/null)" == enabled ]]; }

# check_job <name> <timer-suffix> <script> <when-missing: FAIL text>
check_job() {
  local name="$1" suffix="$2" script="$3" missing="$4" unit timer=false cron=false next result
  unit="$INSTANCE_NAME-$suffix"
  if command -v systemctl > /dev/null 2>&1 && timer_enabled "$unit.timer"; then timer=true; fi
  if [[ "$CRON_TAB_READABLE" == true ]] && printf '%s\n' "$CRON_TAB" | grep -qF -- "$(printf '%q' "$script")"; then cron=true; fi

  if [[ "$timer" == true && "$cron" == true ]]; then
    report WARN schedule "the $name runs from $unit.timer and from a crontab line, so it runs twice; run migrate.sh to drop the cron line"
  elif [[ "$timer" == true ]]; then
    next="$(systemctl show -p NextElapseUSecRealtime --value "$unit.timer" 2> /dev/null)"
    result="$(systemctl show -p Result --value "$unit.service" 2> /dev/null)"
    report OK schedule "$name runs from $unit.timer${next:+ (next: $next)}"
    if [[ -n "$result" && "$result" != success ]]; then
      report WARN schedule "the last $name run of $unit.service ended with '$result'"
    fi
  elif [[ "$cron" == true ]]; then
    report OK schedule "$name runs from a crontab line (no systemd timer)"
  else
    report FAIL schedule "$missing"
  fi
}

check_schedule() {
  read_cron_tab
  if ! command -v systemctl > /dev/null 2>&1 && [[ "$CRON_TAB_READABLE" != true ]]; then
    report SKIP schedule "neither systemctl nor a readable crontab"
    return
  fi
  check_job "hourly backup" backup "$SCRIPTS_DIR/backup/automation/run_backup.sh" \
    "no hourly backup timer or cron line for $USER; backups are not running"
  if [[ "${RESTART_ENABLED:-false}" == true ]]; then
    check_job "scheduled restart" restart "$SCRIPTS_DIR/backup/automation/scheduled_restart.sh" \
      "RESTART_ENABLED is true but there is no scheduled restart timer or cron line for $USER"
  fi
}

check_storage() {
  if [[ ! -d "$BACKUPS_PATH" ]]; then
    # The first backup creates it, so a fresh install has none yet; a folder that is
    # still missing after backups should have run shows up in last-backup too.
    report WARN storage "backups folder $BACKUPS_PATH does not exist yet (the first backup creates it)"
    return
  fi
  local used_bytes max_bytes pct
  used_bytes="$(du -sb --exclude=tmp_backup --exclude=jars --exclude=.stage --exclude=.meta "$BACKUPS_PATH" 2> /dev/null | cut -f1)"
  if [[ "$used_bytes" =~ ^[0-9]+$ && "$MAX_STORAGE_GB" =~ ^[0-9]+$ && "$MAX_STORAGE_GB" -ge 1 ]]; then
    max_bytes=$((MAX_STORAGE_GB * 1024 * 1024 * 1024))
    pct=$((used_bytes * 100 / max_bytes))
    if (( used_bytes > max_bytes )); then
      report FAIL storage "backups use ${pct}% of the ${MAX_STORAGE_GB} GB limit"
    elif (( pct >= 90 )); then
      report WARN storage "backups use ${pct}% of the ${MAX_STORAGE_GB} GB limit"
    else
      report OK storage "backups use ${pct}% of the ${MAX_STORAGE_GB} GB limit"
    fi
  else
    report SKIP storage "could not measure the backups folder"
  fi

  local free_gb min_free="${DOCTOR_MIN_FREE_GB:-5}"
  free_gb="$(df -Pk "$BACKUPS_PATH" 2> /dev/null | awk 'NR == 2 { print int($4 / 1024 / 1024) }')"
  if [[ "$free_gb" =~ ^[0-9]+$ ]]; then
    if (( free_gb < min_free )); then
      report WARN disk-space "only ${free_gb} GB free where the backups live"
    else
      report OK disk-space "${free_gb} GB free where the backups live"
    fi
  fi
}

# The backup scripts record their last run in .meta/last_backup.json; a stale
# or failed entry is caught here without parsing backup.log.
check_last_backup() {
  local f="$BACKUPS_PATH/.meta/last_backup.json" finished rc stage age_h
  if [[ ! -f "$f" ]]; then
    report SKIP last-backup "no run recorded yet (the status file appears after the first backup)"
    return
  fi
  finished="$(sed -n 's/.*"finished":"\([^"]*\)".*/\1/p' "$f" | head -n1)"
  rc="$(sed -n 's/.*"rc":\([0-9]*\).*/\1/p' "$f" | head -n1)"
  stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -n1)"
  age_h=""
  if [[ -n "$finished" ]]; then
    local finished_ts now_ts
    finished_ts="$(date -d "$finished" +%s 2>/dev/null || true)"
    now_ts="$(date +%s)"
    [[ "$finished_ts" =~ ^[0-9]+$ ]] && age_h=$(( (now_ts - finished_ts) / 3600 ))
  fi
  if [[ "$rc" != 0 ]]; then
    report FAIL last-backup "the last backup failed (exit ${rc:-?} at stage ${stage:-?}, ${finished:-unknown time})"
  elif [[ -n "$age_h" ]] && (( age_h >= 3 )); then
    report WARN last-backup "the last successful backup is ${age_h} hours old (${finished})"
  else
    report OK last-backup "last backup succeeded${age_h:+ ${age_h} h ago} (${finished:-unknown time})"
  fi
}

check_sudoers() {
  local dir="${DOCTOR_SUDOERS_DIR:-/etc/sudoers.d}" file found=false bad=0
  for file in "$dir"/mc-service-*-"$INSTANCE_NAME"; do
    [[ -e "$file" ]] || continue
    found=true
    if ! elevated visudo -cf "$file" > /dev/null 2>&1; then bad=$((bad + 1)); fi
  done
  if [[ "$found" == false ]]; then
    report SKIP sudoers "no wrapper service user is set up for $INSTANCE_NAME"
  elif [[ $bad -gt 0 ]]; then
    report FAIL sudoers "$bad sudoers file(s) for $INSTANCE_NAME do not pass visudo -c (or cannot be checked without sudo)"
  else
    report OK sudoers "the wrapper's sudoers rules parse"
  fi
}

# api_status <path>: HTTP status of GET <path> on the local wrapper, with the
# key passed as a curl config line so it never shows in the process list.
api_status() {
  local key="${API_SERVER_KEY:-}"
  key=${key//\\/\\\\}
  key=${key//\"/\\\"}
  printf 'header = "x-api-key: %s"\n' "$key" | curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 3 --max-time 5 --config - "http://127.0.0.1:${API_SERVER_PORT:-3000}$1" 2> /dev/null
}

# The wrapper declares the Node it needs in its package.json (engines.node,
# ">=N"). A host with an older Node still runs it, so this only warns.
# DOCTOR_WRAPPER_DIR and DOCTOR_NODE_MAJOR exist for the tests.
check_wrapper_node() {
  local pkg="${DOCTOR_WRAPPER_DIR:-$SCRIPTS_DIR/../../services/api-server}/package.json" range need have
  [[ -f "$pkg" ]] || return 0
  range="$(awk '/"engines"/ { f = 1 } f && /"node"/ { sub(/.*"node"[[:space:]]*:[[:space:]]*"/, ""); sub(/".*/, ""); print; exit }' "$pkg" 2> /dev/null)"
  [[ "$range" =~ ^\>=[[:space:]]*([0-9]+) ]] || return 0
  need="${BASH_REMATCH[1]}"
  have="${DOCTOR_NODE_MAJOR:-$(node -p 'process.versions.node.split(".")[0]' 2> /dev/null)}"
  [[ "$have" =~ ^[0-9]+$ ]] || return 0
  if (( have < need )); then
    report WARN wrapper-node "Node $have is older than the >=$need the wrapper asks for"
  fi
}

check_wrapper() {
  if [[ "${API_SERVER_ENABLED:-false}" != true ]]; then
    report SKIP wrapper "API_SERVER is not enabled"
    return
  fi
  local code
  code="$(api_status /health)"
  if [[ "$code" != 200 ]]; then
    report FAIL wrapper "GET /health on port ${API_SERVER_PORT:-3000} answered '${code:-nothing}'"
    return
  fi
  report OK wrapper "answers on port ${API_SERVER_PORT:-3000}"
  check_wrapper_node
  code="$(api_status "/instances/$INSTANCE_NAME/running")"
  case "$code" in
    200) report OK wrapper-key "the configured API key is accepted" ;;
    401 | 403) report FAIL wrapper-key "the wrapper rejects API_SERVER.API_KEY from variables.json" ;;
    *) report WARN wrapper-key "GET /instances/$INSTANCE_NAME/running answered '${code:-nothing}'" ;;
  esac
}

check_webhook() {
  if [[ "$TEST_WEBHOOK" != true ]]; then return; fi
  if [[ -z "${WEBHOOK_URL:-}" || "$WEBHOOK_URL" == none ]]; then
    report SKIP webhook "no WEBHOOK_URL configured"
    return
  fi
  if ! command -v jq > /dev/null 2>&1; then
    report FAIL webhook "jq is not installed, so no notification can be built"
    return
  fi
  # The event filter must not hide a test the operator asked for.
  WEBHOOK_EVENTS=""
  notify "webhook_test" "Test notification from doctor.sh. Nothing is wrong."
  if wait_for_notifications --status; then
    report OK webhook "the endpoint accepted the test notification"
  else
    report FAIL webhook "the endpoint did not accept the test notification"
  fi
}

check_xaero_config() {
  local script="$SCRIPT_DIR/xaero_config.sh" out line problems="" ok=0 rc=0 errfile err=""
  if [[ ! -f "$script" ]]; then
    report SKIP xaero-config "xaero_config.sh not installed (run migrate.sh)"
    return
  fi
  errfile="$(mktemp)"
  out="$(bash "$script" check "$SERVER_PATH" 2> "$errfile")" || rc=$?
  err="$(tr '\n' ' ' < "$errfile")"
  rm -f "$errfile"
  while IFS= read -r line; do
    case "$line" in
      OK[[:space:]]*) ok=$((ok + 1)) ;;
      DRIFT[[:space:]]* | MISSING[[:space:]]*) problems+="${problems:+; }${line%% (found*}" ;;
    esac
  done <<< "$out"
  if [[ -n "$problems" ]]; then
    report WARN xaero-config "$problems; run: bash $script apply $SERVER_PATH"
  elif [[ $rc -ne 0 ]]; then
    report WARN xaero-config "xaero_config.sh check failed (exit $rc): ${err:-no error text}"
  elif [[ $ok -gt 0 ]]; then
    report OK xaero-config "the Xaero keys are set"
  else
    report SKIP xaero-config "no Xaero mod installed"
  fi
}

# The optional creative mirror: skipped unless it is switched on for this instance.
# When it is, the mirror's own doctor does the checking and its lines are shown
# here with a mirror- prefix. Nothing else in the suite needs the mirror.
check_mirror() {
  if [[ "${MIRROR_ENABLED:-false}" != true ]]; then
    report SKIP mirror "not configured"
    return
  fi
  local entry="$SCRIPTS_DIR/../../mirror/mirror.sh" out line
  if [[ ! -f "$entry" ]]; then
    report WARN mirror "MIRROR_ENABLED is true but the mirror is not installed ($entry is missing); run mirror.sh setup"
    return
  fi
  out="$(bash "$entry" doctor --scripts-dir "$SCRIPTS_DIR" 2>&1)" || true
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[(OK|WARN|FAIL|SKIP)\]\ ([^:]+):\ (.*)$ ]]; then
      report "${BASH_REMATCH[1]}" "mirror-${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    fi
  done <<< "$out"
}

echo "Doctor: $INSTANCE_NAME"
check_service
check_schedule
check_storage
check_last_backup
check_sudoers
check_wrapper
check_xaero_config
check_mirror
check_webhook

echo "Summary: $N_OK ok, $N_WARN warnings, $N_FAIL failed, $N_SKIP skipped"
[[ $N_FAIL -eq 0 ]]
