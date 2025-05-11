#!/usr/bin/env bash
set -e

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

source "$SCRIPT_DIR/variables.txt"

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

while true
do
  runJavaCommand "${ADDITIONAL_ARGS} ${SERVER_RUN_COMMAND}"
  if [[ "${RESTART}" != "true" ]]; then
    echo "Exiting..."
      if [[ "${WAIT_FOR_USER_INPUT}" == "true" ]]; then
        pause
      fi
    exit 0
  fi
  echo "Automatically restarting server in 5 seconds. Press CTRL + C to abort and exit."
  sleep 5
done