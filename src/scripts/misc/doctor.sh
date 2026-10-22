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

check_cron() {
  local tab rc=0
  if ! command -v crontab > /dev/null 2>&1; then
    report SKIP cron "crontab not found"
    return
  fi
  if [[ "$(id -un)" == "$USER" ]]; then
    tab="$(crontab -l 2>&1)" || rc=$?
  else
    tab="$(sudo -n crontab -u "$USER" -l 2>&1)" || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    if printf '%s' "$tab" | grep -qi 'no crontab'; then
      tab=""
    else
      report SKIP cron "cannot read the crontab of $USER without sudo"
      return
    fi
  fi

  local backup_job restart_job
  backup_job="$(printf '%q' "$SCRIPTS_DIR/backup/automation/run_backup.sh")"
  if printf '%s\n' "$tab" | grep -qF -- "$backup_job"; then
    report OK cron "hourly backup job present"
  else
    report FAIL cron "no hourly backup job for $USER; backups are not running"
  fi
  if [[ "${RESTART_ENABLED:-false}" == true ]]; then
    restart_job="$(printf '%q' "$SCRIPTS_DIR/backup/automation/scheduled_restart.sh")"
    if printf '%s\n' "$tab" | grep -qF -- "$restart_job"; then
      report OK cron "scheduled restart job present"
    else
      report FAIL cron "RESTART_ENABLED is true but there is no scheduled restart job for $USER"
    fi
  fi
}

check_storage() {
  if [[ ! -d "$BACKUPS_PATH" ]]; then
    report FAIL storage "backups folder $BACKUPS_PATH does not exist"
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
    local then now
    then="$(date -d "$finished" +%s 2> /dev/null || true)"
    now="$(date +%s)"
    [[ "$then" =~ ^[0-9]+$ ]] && age_h=$(( (now - then) / 3600 ))
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

echo "Doctor: $INSTANCE_NAME"
check_service
check_cron
check_storage
check_last_backup
check_sudoers
check_wrapper
check_xaero_config
check_webhook

echo "Summary: $N_OK ok, $N_WARN warnings, $N_FAIL failed, $N_SKIP skipped"
[[ $N_FAIL -eq 0 ]]
