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

  if (( rapid_crashes >= MAX_RAPID_CRASHES )); then
    echo "Server crashed ${rapid_crashes} times, each within ${CRASH_LOOP_WINDOW_SECONDS}s of starting — giving up rather than retrying forever." >&2
    echo "This is a startup-time failure (an incompatible mod, a corrupted config/world file, a missing dependency) that will not fix itself on retry. Check the log above, fix the cause, then restart the service." >&2
    if [[ "${WAIT_FOR_USER_INPUT}" == "true" ]]; then
      pause
    fi
    exit 1
  fi

  echo "Automatically restarting server in 15 seconds. Press CTRL + C to abort and exit."
  sleep 15
done