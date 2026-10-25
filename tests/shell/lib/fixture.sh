#!/bin/bash
# Builds a throwaway fake instance: copies of the scripts under test, a
# variables.txt pointing at scratch directories, fake binaries on PATH, and a
# small "world". Nothing here ever touches real server data or real systemd.

SHELL_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_SRC="$(cd "$SHELL_TEST_DIR/../../src/scripts" && pwd)"

# Resolved once, before any shim directory is put on PATH.
export REAL_TAR="${REAL_TAR:-$(command -v tar)}"
export REAL_DATE="${REAL_DATE:-$(command -v date)}"
export REAL_DU="${REAL_DU:-$(command -v du)}"
export REAL_DF="${REAL_DF:-$(command -v df)}"
REAL_FLOCK="$(command -v flock || true)"
export REAL_FLOCK
REAL_RSYNC="$(command -v rsync || true)"
REAL_ZSTD="$(command -v zstd || true)"
export REAL_RSYNC REAL_ZSTD

# MC_TEST_REAL_TOOLS=1 makes the rsync and zstd shims defer to the real tools
# (CI installs both); archives are then real zstd streams. Without it they are
# gzip streams under a .tar.zst name, which the zstd shim reads.
real_tools() { [[ "${MC_TEST_REAL_TOOLS:-}" == 1 && -n "$REAL_RSYNC" && -n "$REAL_ZSTD" ]]; }
if [[ "${MC_TEST_REAL_TOOLS:-}" == 1 ]] && ! real_tools; then
  echo "MC_TEST_REAL_TOOLS=1 but rsync or zstd is missing; using the shims" >&2
  unset MC_TEST_REAL_TOOLS
fi

# compress_stream / archive_list <file> / archive_ok <file>: the container the
# fixture's archives use, in either mode.
compress_stream() { if real_tools; then "$REAL_ZSTD" -q -c; else gzip -c; fi; }
archive_list() {
  if [[ "$1" == *.tar.gz ]]; then "$REAL_TAR" -tzf "$1"
  elif real_tools; then "$REAL_ZSTD" -dc "$1" | "$REAL_TAR" -tf -
  else "$REAL_TAR" -tzf "$1"; fi
}
archive_ok() {
  if [[ "$1" == *.tar.gz ]]; then gzip -t "$1" 2>/dev/null
  elif real_tools; then "$REAL_ZSTD" -t "$1" 2>/dev/null
  else gzip -t "$1" 2>/dev/null; fi
}

make_fixture() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-shelltest.XXXXXX")"
  export T
  mkdir -p "$T/scripts" "$T/server/world" "$T/backups" "$T/bin" "$T/state"

  cp -r "$SCRIPTS_SRC/backup" "$SCRIPTS_SRC/common" "$SCRIPTS_SRC/misc" "$T/scripts/"
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
        SYSTEMCTL_STOP_RC FLOCK_SHIM_BUSY SCREEN_SHIM_SAVE_LOG SCREEN_SHIM_LIST_REPLY SCREEN_SHIM_SESSION NODE_SHIM_RCON_RC NODE_SHIM_RCON_OUT SAVE_TIMEOUT_SECONDS INSTANCE_LOCK_DIR DU_SHIM_BYTES CURL_SHIM_GATE CURL_SHIM_RC CURL_SHIM_HEALTH_CODE CURL_SHIM_RUNNING_CODE SYSTEMCTL_SHIM_UNIT SYSTEMCTL_SHIM_UNITS SYSTEMD_USABLE TIMER_SUDO SSH_SHIM_ROOT SSH_SHIM_FAIL SSH_SHIM_FAIL_AFTER INSTANCE_LOCK_DIR DATE_SHIM_DOW DATE_SHIM_DOM CRONTAB_SHIM_TEXT CRONTAB_SHIM_NONE VISUDO_SHIM_RC DOCTOR_SUDOERS_DIR DOCTOR_MIN_FREE_GB SYSTEMD_UNIT_DIR BACKUP_UMASK INSTALL_UNITS \
        RSYNC_SHIM_EXIT ZSTD_SHIM_FAIL_DECOMPRESS ZSTD_SHIM_ENOSPC ZSTD_SHIM_STALL IONICE_SHIM_FAIL DF_SHIM_AVAIL TIMEOUT_SHIM_EXPIRE \
        BK_EXTRA_TIERS BACKUP_STAGING_MODE BACKUP_HOURLY_LEVEL BACKUP_ARCHIVE_LEVEL BACKUP_ZSTD_THREADS BACKUP_TIMEOUT_MINUTES \
        BACKUP_SKIP_ALERT_AFTER BACKUP_ARCHIVE_MAX_ATTEMPTS BACKUP_LOG_MAX_MB BACKUP_SPACE_MARGIN_PCT BACKUP_FOLLOW_SYMLINKS \
        BACKUP_EXTRA_EXCLUDES RESTORE_KEEP_OLD RESTORE_KEEP_OLD_DAYS RESTORE_CARRY_OVER MC_OPERATION_LOCK_HELD

  seed_world current
}

cleanup_fixture() { [[ -n "${T:-}" && "$T" == */mcsetup-shelltest.* ]] && rm -rf "$T"; }

# seed_world <label>: fill the live server dir with recognisable content.
seed_world() {
  rm -rf "${T:?}/server"
  mkdir -p "$T/server/world/region" "$T/server/logs"
  echo "$1" > "$T/server/world/level.dat"
  echo "$1-region" > "$T/server/world/region/r.0.0.mca"
  echo "$1" > "$T/server/server.properties"
  echo "$1-dotfile" > "$T/server/.live_dotfile"
  echo "$1-log" > "$T/server/logs/latest.log"
}

server_running() { touch "$SHIM_STATE/screen_running"; }

# use_rcon_shim: switch the fixture to RCON and put a node wrapper on PATH that
# answers calls to rcon.js (logged as "node <args>") and runs everything else
# with the real node. NODE_SHIM_RCON_RC is its exit status (default 0) and
# NODE_SHIM_RCON_OUT what it prints.
use_rcon_shim() {
  printf 'USE_RCON="true"\nRCON_PASSWORD="pw"\n' >> "$T/scripts/common/variables.txt"
  REAL_NODE="$(PATH="${PATH#"$T/bin:"}" command -v node)"
  export REAL_NODE
  cat > "$T/bin/node" <<'SH'
#!/bin/bash
if [[ "$1" == */rcon.js ]]; then
  echo "node $*" >> "$SHIM_LOG"
  [[ -n "${NODE_SHIM_RCON_OUT:-}" ]] && echo "$NODE_SHIM_RCON_OUT"
  exit "${NODE_SHIM_RCON_RC:-0}"
fi
exec "$REAL_NODE" "$@"
SH
  chmod +x "$T/bin/node"
}

# write_sidecar <archive>: the .meta/ sidecar backup.sh writes at publish time,
# for an archive inside the fixture's backups folder (restore and rollback only
# pick an archive by name when its sidecar or its mtime backs the name).
write_sidecar() {
  local dest="$1" rel
  [[ "$dest" == "$T/backups/"* ]] || return 0
  rel="${dest#"$T/backups/"}"
  mkdir -p "$T/backups/.meta/$(dirname "$rel")"
  echo "$(sha256sum -- "$dest" | cut -d' ' -f1)  $(basename "$dest")" > "$T/backups/.meta/$rel.sha256"
}

# make_archive <dest.tar.zst> <label>: archive of a world tagged <label>, in the
# gzip container the zstd shim reads.
make_archive() {
  local dest="$1" label="$2" src
  src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world/region"
  echo "$label" > "$src/world/level.dat"
  echo "$label-region" > "$src/world/region/r.0.0.mca"
  echo "$label" > "$src/server.properties"
  echo "$label-dotfile" > "$src/.restored_dotfile"
  mkdir -p "$(dirname "$dest")"
  "$REAL_TAR" -cf - -C "$src" . | compress_stream > "$dest"
  write_sidecar "$dest"
  rm -rf "$src"
}

# make_archive_from <dest> <src-dir>: archive of an arbitrary tree.
make_archive_from() {
  mkdir -p "$(dirname "$1")"
  "$REAL_TAR" -cf - -C "$2" . | compress_stream > "$1"
  write_sidecar "$1"
}

# make_archive_with_unit <dest.tar.zst> <label> <unit-name> <unit-text>: like
# make_archive, plus a .mc-meta/systemd unit file.
make_archive_with_unit() {
  local dest="$1" label="$2" unit="$3" text="$4" src
  src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world/region" "$src/.mc-meta/systemd"
  echo "$label" > "$src/world/level.dat"
  echo "$label-region" > "$src/world/region/r.0.0.mca"
  echo "$text" > "$src/.mc-meta/systemd/$unit"
  mkdir -p "$(dirname "$dest")"
  "$REAL_TAR" -cf - -C "$src" . | compress_stream > "$dest"
  write_sidecar "$dest"
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
  OUT="$(cd "$T/scripts" && script -qec "$cmd" /dev/null 2>&1 < /dev/null)"
  RC=$?
  OUT="${OUT//$'\r'/}"
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
