#!/bin/bash
# Helpers shared by create_backup_job.sh and create_restart_job.sh. Source it.

# cron_quote <path>: the path as one shell word for a crontab line. A literal
# % is a newline to cron, so it is escaped too.
cron_quote() {
  local quoted
  quoted="$(printf '%q' "$1")"
  printf '%s\n' "${quoted//%/\\%}"
}

# read_crontab: sets EXISTING_CRONTAB to the user's crontab, empty when there
# is none. Any other failure of `crontab -l` stops the script: writing back a
# crontab built from nothing would erase the jobs that could not be read.
read_crontab() {
  local out rc=0
  out="$(crontab -l 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    EXISTING_CRONTAB="$out"
  elif printf '%s' "$out" | grep -qi 'no crontab'; then
    EXISTING_CRONTAB=""
  else
    echo "Could not read the current crontab (crontab -l failed: $out). Nothing was changed." >&2
    exit 1
  fi
}
