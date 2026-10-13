#!/usr/bin/env bash
# Deliberately no top-level `set -e`. This script's job past variable loading
# is "run the JVM in a loop and survive it crashing" (RESTART=true below), and
# `set -e` defeated that: the instant `runJavaCommand` returned the JVM's
# non-zero exit code, the ENTIRE script terminated immediately, so the
# while-loop's "restarting in 15 seconds" backoff and the crash-loop guard
# below it could never run. Control fell straight through to whatever manages
# this script (systemd's `Restart=always`/`RestartSec=3s` in the generated
# unit, with no cap of its own), which then re-ran the same failing JVM
# invocation as fast as it was allowed to — dozens of times a minute against
# an unchanged, still-broken jar (an incompatible mod is the classic trigger:
# it fails identically on every attempt) instead of the intended slow,
# capped retry. Steps below check their own exit status explicitly instead.
set -o pipefail

pause() {
  read -n 1 -s -r -p "Press any key to continue"
}

exitServer() {
  local message="$1"
  echo "$message"
  pause
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -s "$SCRIPT_DIR/variables.txt" ]]; then
  exitServer "ERROR! variables.txt not present. Without it the server can not be installed, configured or started."
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/variables.txt" || exitServer "ERROR! Failed to read variables.txt."

SERVER_RUN_COMMAND="DO_NOT_EDIT"

setup_server_run_command() {
    if [ "$USE_FABRIC" = "true" ]; then
        SERVER_JAR="fabric-server-launch.jar"
        SERVER_RUN_COMMAND="${JAVA_ARGS} -jar ${SERVER_JAR} nogui"
    else
        SERVER_JAR="server.jar"
        SERVER_RUN_COMMAND="${JAVA_ARGS} -jar ${SERVER_JAR} nogui"
    fi
}
    
runJavaCommand() {
    local command="$1"
    
    # Use the JAVA variable set in variables.txt
    local java_command="${JAVA} ${command}"
    
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "Running command: ${java_command}"
    fi
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "Dry run: ${java_command}"
    else
        # Execute the java command using the JAVA variable
        ${JAVA} ${command}
    fi
}

setup_server_run_command

# ── Lifecycle events ─────────────────────────────────────────────────────────
# One JSON object per line in logs/lifecycle.ndjson, for anything that wants to
# know how the JVM is doing without scraping the console (the API wrapper
# serves it; the update job reads it). Values are numbers or short strings,
# never log content. Restart behaviour below is unchanged by this.
EVENTS_FILE="${LIFECYCLE_EVENTS_FILE:-$SCRIPT_DIR/logs/lifecycle.ndjson}"
EVENTS_MAX_BYTES=1048576

_json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}

# emit_event <type> [key=value ...]
emit_event() {
  local type="$1"; shift
  local line pair key value
  line="{\"ts\":$(date +%s),\"type\":$(_json_string "$type")"
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
      line+=",$(_json_string "$key"):$value"
    else
      line+=",$(_json_string "$key"):$(_json_string "$value")"
    fi
  done
  line+="}"
  {
    mkdir -p "$(dirname "$EVENTS_FILE")"
    if [[ -f "$EVENTS_FILE" ]] && (( $(wc -c < "$EVENTS_FILE") > EVENTS_MAX_BYTES )); then
      mv -f "$EVENTS_FILE" "$EVENTS_FILE.1"
    fi
    printf '%s\n' "$line" >> "$EVENTS_FILE"
  } 2> /dev/null || true
}

# Best effort: the scripts dir sits next to instances/ and holds the webhook helper.
notify_crash_loop() {
  local instance webhook
  instance="$(basename "$SCRIPT_DIR")"
  webhook="$SCRIPT_DIR/../../scripts/$instance/common/webhook.sh"
  [[ -f "$webhook" ]] || return 0
  (
    export INSTANCE_NAME="$instance"
    # shellcheck source=/dev/null
    source "$webhook" && notify server_crash_loop "$1" "$instance" 15158332 && wait_for_notifications
  ) > /dev/null 2>&1 || true
}

newest_crash_report() {
  local dir="$SCRIPT_DIR/crash-reports"
  [[ -d "$dir" ]] || return 0
  # shellcheck disable=SC2012
  ls -1t "$dir" 2> /dev/null | head -n 1
}

# A crash within this many seconds of starting is "the JVM never really came
# up" (a bad jar, an incompatible mod, a corrupt config) rather than "it ran
# for a while and then something went wrong" — and unlike the latter, retrying
# it changes nothing: the same broken jars produce the same failure every
# time. Left unbounded, that becomes exactly what this guard exists to stop:
# dozens of restarts a minute, indefinitely, until a person notices and fixes
# the actual cause by hand.
CRASH_LOOP_WINDOW_SECONDS=30
MAX_RAPID_CRASHES=5
rapid_crashes=0

while true
do
  start_ts=$(date +%s)
  emit_event jvm_start "rapid_crashes=$rapid_crashes"
  runJavaCommand "${ADDITIONAL_ARGS} ${SERVER_RUN_COMMAND}"
  exit_code=$?
  uptime=$(( $(date +%s) - start_ts ))

  if [[ "${RESTART}" != "true" ]]; then
    echo "Exiting..."
      if [[ "${WAIT_FOR_USER_INPUT}" == "true" ]]; then
        pause
      fi
    exit 0
  fi

  if (( exit_code != 0 && uptime < CRASH_LOOP_WINDOW_SECONDS )); then
    rapid_crashes=$(( rapid_crashes + 1 ))
  else
    rapid_crashes=0
  fi

  emit_event jvm_exit "exit_code=$exit_code" "uptime_seconds=$uptime" "rapid_crashes=$rapid_crashes"

  if (( rapid_crashes >= MAX_RAPID_CRASHES )); then
    emit_event crash_loop_gave_up "rapid_crashes=$rapid_crashes" "window_seconds=$CRASH_LOOP_WINDOW_SECONDS" "exit_code=$exit_code" "crash_report=$(newest_crash_report)"
    notify_crash_loop "The server crashed ${rapid_crashes} times within ${CRASH_LOOP_WINDOW_SECONDS}s of starting and the restart loop gave up."
    echo "Server crashed ${rapid_crashes} times, each within ${CRASH_LOOP_WINDOW_SECONDS}s of starting — giving up rather than retrying forever." >&2
    echo "This is a startup-time failure (an incompatible mod, a corrupted config/world file, a missing dependency) that will not fix itself on retry. Check the log above, fix the cause, then restart the service." >&2
    if [[ "${WAIT_FOR_USER_INPUT}" == "true" ]]; then
      pause
    fi
    exit 1
  fi

  echo "Automatically restarting server in 15 seconds. Press CTRL + C to abort and exit."
  emit_event restart_scheduled "seconds=15"
  sleep 15
done