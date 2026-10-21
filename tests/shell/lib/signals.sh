#!/bin/bash
# Helpers for tests that deliver real signals. Needs assert.sh (skip) to be sourced.

# Returns 0 after printing a skip line when signals cannot be tested reliably on this host.
signals_unreliable() { # test-label
  case "$(uname -o 2> /dev/null)" in
    Msys | Cygwin)
      skip "$1" "signals are unreliable under MSYS/Cygwin; covered on Linux CI"
      return 0
      ;;
  esac
  if ! command -v perl > /dev/null 2>&1; then
    skip "$1" "perl is needed to restore the default signal handling of background jobs"
    return 0
  fi
  return 1
}

# A background job of a non-interactive shell (or of a backgrounded test run) inherits an
# ignored SIGINT that bash cannot undo, so jobs start through a small exec wrapper that
# restores the default dispositions.
sig_exec() {
  if command -v perl > /dev/null 2>&1; then
    perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' -- "$@"
  else
    "$@"
  fi
}

# Polls for a marker file (up to ~60 s), signals the whole process group, and waits for the
# leader to end (up to ~60 s). On every path it then releases the stalling shims (the
# optional release-marker arguments), kills whatever is left of the group and reaps the
# leader. Sets SIGNAL_STATUS to the leader's wait status.
signal_when_started() { # signal pid marker [release-marker...]
  local sig="$1" pid="$2" marker="$3" i release
  shift 3
  for ((i = 0; i < 600; i++)); do
    [ -e "$marker" ] && break
    sleep 0.1
  done
  kill -s "$sig" -- "-$pid" 2> /dev/null
  for ((i = 0; i < 600; i++)); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.1
  done
  for release in "$@"; do : > "$release"; done
  kill -9 -- "-$pid" 2> /dev/null
  kill -9 "$pid" 2> /dev/null
  SIGNAL_STATUS=0
  wait "$pid" 2> /dev/null || SIGNAL_STATUS=$?
}
