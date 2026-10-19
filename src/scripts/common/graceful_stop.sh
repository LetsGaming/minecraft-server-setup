#!/bin/bash
# ExecStop of the instance's systemd unit: flush the world to disk while the
# server is still up, so systemd's stop (SIGTERM, then SIGKILL after
# TimeoutStopSec) only has to end a process that has nothing left to write.
#
# It does not send "stop": start.sh restarts a JVM that exits, so a console
# stop would only bring the server straight back. Always exits 0; a save that
# is not confirmed is reported and systemd stops the server regardless.

_GS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_GS_DIR/server_control.sh"
set +e

if ! server_reachable; then
  exit 0
fi

if ! save_and_wait; then
  echo "[WARN] The save was not confirmed before the stop."
fi
exit 0
