#!/bin/bash
# Shared by the creative mirror jobs (bin/export.sh, bin/pull.sh). Sourced.
#
# The mirror reuses the instance's deployed suite scripts (server_control.sh for
# the console and RCON, utils.sh for the operation lock, webhook.sh through
# server_control.sh) and reads its settings from that instance's
# common/variables.txt. Nothing in the suite sources this file: the mirror
# depends on the suite, never the other way round.
#
# Needs MIRROR_SCRIPTS_DIR (the instance's deployed scripts folder) in the
# environment before mirror_load runs.

EX_STALE=65
EX_UNAVAILABLE=69
EX_NOSPACE=73
EX_LOCKED=75
EX_CONFIG=78

FAIL_REASON=""

mirror_log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}"; }
# Errors go to stderr, so a die inside a $(...) is not swallowed into its value.
mirror_die() { local rc=$1; shift; mirror_log ERROR "$*" >&2; FAIL_REASON="$*"; exit "$rc"; }

# Matches the server's "Done" line at the end of a start (26.x and older).
MIRROR_DONE_RE='^\[[0-9:]+\] \[[^]/]+/INFO\]: Done \([0-9.]+s\)!'

# mirror_load: sources the suite's helpers and fills in every MIRROR_* default.
mirror_load() {
  [[ -n "${MIRROR_SCRIPTS_DIR:-}" ]] || { mirror_log ERROR "MIRROR_SCRIPTS_DIR is not set (pass --scripts-dir)"; exit "$EX_CONFIG"; }
  MIRROR_SCRIPTS_DIR="$(cd "$MIRROR_SCRIPTS_DIR" 2> /dev/null && pwd)" || { mirror_log ERROR "scripts folder not found"; exit "$EX_CONFIG"; }
  local f
  for f in common/server_control.sh common/utils.sh; do
    [[ -f "$MIRROR_SCRIPTS_DIR/$f" ]] || { mirror_log ERROR "$MIRROR_SCRIPTS_DIR/$f is missing; is this a deployed suite scripts folder?"; exit "$EX_CONFIG"; }
  done
  # shellcheck source=/dev/null
  source "$MIRROR_SCRIPTS_DIR/common/server_control.sh"
  # shellcheck source=/dev/null
  source "$MIRROR_SCRIPTS_DIR/common/utils.sh"

  MIRROR_ENABLED="${MIRROR_ENABLED:-false}"
  MIRROR_ROLE="${MIRROR_ROLE:-}"
  MIRROR_REMOTE="${MIRROR_REMOTE:-}"
  MIRROR_SSH_PORT="${MIRROR_SSH_PORT:-22}"
  MIRROR_SOURCE_MODE="${MIRROR_SOURCE_MODE:-live}"
  MIRROR_DIMS="${MIRROR_DIMS:-minecraft/overworld}"
  MIRROR_BWLIMIT_KIB="${MIRROR_BWLIMIT_KIB:-40000}"
  MIRROR_RSYNC_TIMEOUT="${MIRROR_RSYNC_TIMEOUT:-600}"
  MIRROR_RETRIES="${MIRROR_RETRIES:-3}"
  MIRROR_RETRY_DELAY="${MIRROR_RETRY_DELAY:-120}"
  MIRROR_MAX_SNAPSHOT_AGE_H="${MIRROR_MAX_SNAPSHOT_AGE_H:-30}"
  MIRROR_REQUIRE_SAME_VERSION="${MIRROR_REQUIRE_SAME_VERSION:-true}"
  MIRROR_PARITY="${MIRROR_PARITY:-warn}"
  MIRROR_WORLDGEN_MODS="${MIRROR_WORLDGEN_MODS:-c2me|terralith|tectonic|lithostitched|nullscape|incendium|biomesoplenty|worldgen}"
  MIRROR_MIN_REGION_RATIO_PCT="${MIRROR_MIN_REGION_RATIO_PCT:-50}"
  # 0 means no cap on the snapshot size; a region file is never legitimately near 2 GiB.
  MIRROR_MAX_SNAPSHOT_GB="${MIRROR_MAX_SNAPSHOT_GB:-0}"
  MIRROR_MAX_FILE_SIZE="${MIRROR_MAX_FILE_SIZE:-2G}"
  MIRROR_WARN_SECONDS="${MIRROR_WARN_SECONDS:-60}"
  MIRROR_STOP_TIMEOUT="${MIRROR_STOP_TIMEOUT:-360}"
  MIRROR_START_TIMEOUT="${MIRROR_START_TIMEOUT:-300}"
  MIRROR_SAVE_OFF_MAX="${MIRROR_SAVE_OFF_MAX:-600}"
  MIRROR_KEEP_SNAPSHOTS="${MIRROR_KEEP_SNAPSHOTS:-2}"
  MIRROR_LOCK_WAIT="${MIRROR_LOCK_WAIT:-1800}"
  MIRROR_STAGE_MAX_AGE_MIN="${MIRROR_STAGE_MAX_AGE_MIN:-90}"
  MIRROR_STOP_CMD="${MIRROR_STOP_CMD:-sudo -n systemctl stop $INSTANCE_NAME.service}"
  MIRROR_START_CMD="${MIRROR_START_CMD:-sudo -n systemctl start $INSTANCE_NAME.service}"

  local base
  base="$(cd "$MIRROR_SCRIPTS_DIR/../.." && pwd)"
  MIRROR_HOME="${MIRROR_HOME:-$base/mirror}"
  MIRROR_STATE="${MIRROR_STATE:-$MIRROR_HOME/$INSTANCE_NAME}"
  MIRROR_EXPORT_ROOT="${MIRROR_EXPORT_ROOT:-$MIRROR_STATE/export}"
  MIRROR_SYNC_ROOT="${MIRROR_SYNC_ROOT:-$MIRROR_STATE/sync}"
  MIRROR_SSH_KEY="${MIRROR_SSH_KEY:-$MIRROR_STATE/ssh/id_ed25519}"
  MIRROR_KNOWN_HOSTS="${MIRROR_KNOWN_HOSTS:-$MIRROR_STATE/ssh/known_hosts}"
  SERVER_DIR="$SERVER_PATH"
  CHUNK_DIRS="region entities poi"
}

# mirror_require <role>: the role this job belongs to must be configured.
mirror_require() {
  [[ "$MIRROR_ENABLED" == true ]] || mirror_die "$EX_CONFIG" "the mirror is not enabled for $INSTANCE_NAME (MIRROR_ENABLED is not true; run mirror.sh setup)"
  [[ "$MIRROR_ROLE" == "$1" ]] || mirror_die "$EX_CONFIG" "this job needs MIRROR_ROLE=$1, but $INSTANCE_NAME is '${MIRROR_ROLE:-unset}'"
}

mirror_validate_dims() {
  local dim
  for dim in $MIRROR_DIMS; do
    [[ "$dim" =~ ^minecraft/(overworld|the_nether|the_end)$ ]] ||
      mirror_die "$EX_CONFIG" "MIRROR_DIMS may only list minecraft/overworld, minecraft/the_nether, minecraft/the_end (got $dim)"
  done
}

# mirror_notify <event> <message>: through the suite's webhook helper; a missing
# or failing webhook never fails a job.
mirror_notify() {
  declare -F notify > /dev/null || return 0
  notify "$1" "$2" "$INSTANCE_NAME mirror" > /dev/null 2>&1 || mirror_log WARN "webhook delivery failed"
}

mirror_level_name() {
  local name
  name="$(sed -n 's/^level-name=//p' "$SERVER_DIR/server.properties" 2> /dev/null | tail -n 1 | tr -d '\r')"
  name="${name:-world}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != ".." ]] || mirror_die "$EX_CONFIG" "unsupported level-name: $name"
  printf '%s\n' "$name"
}

mirror_level_seed() {
  local seed
  seed="$(sed -n 's/^level-seed=//p' "$SERVER_DIR/server.properties" 2> /dev/null | tail -n 1 | tr -d '\r')"
  printf '%s\n' "${seed:-unknown}"
}

# The Minecraft version the server runs. The suite's own record comes first, then
# the server's versions/ folder; the log is the last resort because Minecraft
# rolls latest.log over (at midnight, or at a restart), so a server that has been
# up for a day no longer has its "Starting minecraft server version" line there.
# "unknown" when nothing says (guarded, so it never aborts a job under set -e).
mirror_mc_version() {
  local v="" dirs
  v="$(sed -n 's/.*"gameVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MIRROR_SCRIPTS_DIR/common/downloaded_versions.json" 2> /dev/null | head -n 1)" || true
  if [[ -z "$v" && -d "$SERVER_DIR/versions" ]]; then
    dirs="$(find "$SERVER_DIR/versions" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2> /dev/null)" || true
    [[ -n "$dirs" && "$(printf '%s\n' "$dirs" | wc -l)" -eq 1 ]] && v="$dirs"
  fi
  if [[ -z "$v" ]]; then
    v="$(grep -oE 'Starting minecraft server version [^ ]+' "$LOG_FILE" 2> /dev/null | tail -n 1 | awk '{print $NF}')" || true
  fi
  printf '%s\n' "${v:-unknown}"
}

# The Fabric Loader the server runs, from its libraries folder.
mirror_loader_version() {
  local v
  v="$(ls "$SERVER_DIR/libraries/net/fabricmc/fabric-loader" 2> /dev/null | sort -V | tail -n 1)" || true
  printf '%s\n' "${v:-none}"
}

# The jar names of mods that change world generation (MIRROR_WORLDGEN_MODS is a
# case-insensitive alternation), sorted and joined with "|". Both servers must
# agree on these, or newly generated chunks differ.
mirror_worldgen_mods() {
  local list
  list="$(find "$SERVER_DIR/mods" -maxdepth 1 -type f -name '*.jar' -printf '%f\n' 2> /dev/null | grep -iE "$MIRROR_WORLDGEN_MODS" | sort | paste -sd '|' -)" || true
  printf '%s\n' "${list:-none}"
}

mirror_manifest_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2> /dev/null; }

# "<files> <bytes>" for region files below the given directories; leftovers in
# .rsync-partial must not count or verification never passes.
mirror_tree_stats() {
  find "$@" -name .rsync-partial -prune -o -type f -name 'r.*.*.mca' -printf '%s\n' 2> /dev/null |
    awk '{n++; s += $1} END {printf "%d %d\n", n, s}'
}

# Bytes free where the path lives.
mirror_avail_bytes() { df -B1 --output=avail "$1" | tail -n 1 | tr -d ' '; }

# mirror_take_operation_lock <kind>: the suite's one slot for work that rewrites
# the server (backup, restore, rollback, upgrade). The suite's helper does not
# wait, so this polls for up to MIRROR_LOCK_WAIT seconds; a backup that is
# running simply finishes first.
mirror_take_operation_lock() {
  local waited=0
  while ! acquire_operation_lock "$1" > /dev/null 2>&1; do
    ((waited < MIRROR_LOCK_WAIT)) || mirror_die "$EX_LOCKED" "another operation held the instance lock for ${MIRROR_LOCK_WAIT}s"
    sleep 10
    waited=$((waited + 10))
  done
}
