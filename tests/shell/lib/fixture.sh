#!/bin/bash
# Builds a throwaway fake instance: copies of the scripts under test, a
# variables.txt pointing at scratch directories, fake binaries on PATH, and a
# small "world". Nothing here ever touches real server data or real systemd.

SHELL_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_SRC="$(cd "$SHELL_TEST_DIR/../../src/scripts" && pwd)"

# Resolved once, before any shim directory is put on PATH.
export REAL_TAR="${REAL_TAR:-$(command -v tar)}"
export REAL_DU="${REAL_DU:-$(command -v du)}"
REAL_FLOCK="$(command -v flock || true)"
export REAL_FLOCK

make_fixture() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-shelltest.XXXXXX")"
  export T
  mkdir -p "$T/scripts" "$T/server/world" "$T/backups" "$T/bin" "$T/state"

  cp -r "$SCRIPTS_SRC/backup" "$SCRIPTS_SRC/common" "$T/scripts/"
  cp "$SCRIPTS_SRC"/*.sh "$T/scripts/"

  cat > "$T/scripts/common/variables.txt" <<VARS
USER="tester"
INSTANCE_NAME="testinst"
SERVER_PATH="$T/server"
BACKUPS_PATH="$T/backups"
COMPRESSION_LEVEL="3"
MAX_STORAGE_GB="10"
DO_GENERATION_BACKUPS="false"
MAX_HOURLY_BACKUPS="5"
MAX_DAILY_BACKUPS="5"
MAX_WEEKLY_BACKUPS="5"
MAX_MONTHLY_BACKUPS="5"
USE_RCON="false"
WEBHOOK_URL=""
VARS

  local f
  for f in "$SHELL_TEST_DIR"/shims/*; do
    cp "$f" "$T/bin/"
  done
  chmod +x "$T"/bin/*

  export SHIM_LOG="$T/shim.log"
  export SHIM_STATE="$T/state"
  : > "$SHIM_LOG"
  export INSTANCE_NAME=testinst
  export PATH="$T/bin:$PATH"
  unset TAR_SHIM_FAIL_CREATE TAR_SHIM_FAIL_EXTRACT TAR_SHIM_FAIL_LIST TAR_SHIM_START_SERVER ZSTD_SHIM_FAIL_TEST RSYNC_SHIM_FAIL \
        SYSTEMCTL_STOP_RC FLOCK_SHIM_BUSY SCREEN_SHIM_SAVE_LOG SCREEN_SHIM_SESSION INSTANCE_LOCK_DIR DU_SHIM_BYTES CURL_SHIM_GATE SYSTEMD_UNIT_DIR BACKUP_UMASK INSTALL_UNITS

  seed_world current
}

cleanup_fixture() { [[ -n "${T:-}" && "$T" == */mcsetup-shelltest.* ]] && rm -rf "$T"; }

# seed_world <label>: fill the live server dir with recognisable content.
seed_world() {
  rm -rf "${T:?}/server"
  mkdir -p "$T/server/world" "$T/server/logs"
  echo "$1" > "$T/server/world/level.dat"
  echo "$1" > "$T/server/server.properties"
  echo "$1-dotfile" > "$T/server/.live_dotfile"
}

server_running() { touch "$SHIM_STATE/screen_running"; }

# make_archive <dest.tar.zst> <label>: archive of a world tagged <label>, in the
# gzip container the zstd shim reads.
make_archive() {
  local dest="$1" label="$2" src
  src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world"
  echo "$label" > "$src/world/level.dat"
  echo "$label" > "$src/server.properties"
  echo "$label-dotfile" > "$src/.restored_dotfile"
  mkdir -p "$(dirname "$dest")"
  "$REAL_TAR" -cf - -C "$src" . | gzip -c > "$dest"
  rm -rf "$src"
}

# make_archive_with_unit <dest.tar.zst> <label> <unit-name> <unit-text>: like
# make_archive, plus a .mc-meta/systemd unit file.
make_archive_with_unit() {
  local dest="$1" label="$2" unit="$3" text="$4" src
  src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world" "$src/.mc-meta/systemd"
  echo "$label" > "$src/world/level.dat"
  echo "$text" > "$src/.mc-meta/systemd/$unit"
  mkdir -p "$(dirname "$dest")"
  "$REAL_TAR" -cf - -C "$src" . | gzip -c > "$dest"
  rm -rf "$src"
}

run_script() { # script args... ; sets OUT and RC
  OUT="$(cd "$T/scripts" && bash "$@" 2>&1 < /dev/null)"
  RC=$?
}

# run_script_tty: like run_script, but with a terminal on stdin, the way an
# operator runs a script by hand. Needs util-linux `script`.
run_script_tty() {
  local cmd
  cmd="bash $(printf '%q ' "$@")"
  OUT="$(cd "$T/scripts" && script -qec "$cmd" /dev/null 2>&1 < /dev/null | tr -d '\r')"
  RC=${PIPESTATUS[0]}
}

# use_install_layout: move the fixture into the layout setup creates, so scripts
# that derive the install root from their own path see a real one:
#   $R/scripts/testinst  $R/instances/testinst  $R/services/
# Run scripts there with run_in_layout (run_script would cd into $T/scripts).
use_install_layout() {
  R="$T/mc-root"
  mkdir -p "$R/scripts" "$R/instances" "$R/services"
  mv "$T/scripts" "$R/scripts/testinst"
  mv "$T/server" "$R/instances/testinst"
  sed -i "s|^SERVER_PATH=.*|SERVER_PATH=\"$R/instances/testinst\"|" "$R/scripts/testinst/common/variables.txt"
}

run_in_layout() { # script args... ; sets OUT and RC
  OUT="$(cd "$R/scripts/testinst" && bash "$@" 2>&1 < /dev/null)"
  RC=$?
}
