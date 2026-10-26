#!/bin/bash
# Mirror pull: runs on the target (creative) server as the server owner.
# Pulls the newest snapshot of the source over rsync+SSH (a read-only rrsync key)
# into a local pull cache, pre-stages a copy next to the world, then stops the
# server, swaps only the mirrored dimensions' chunk folders and starts it again.
# The plot dimension, level.dat, data/ and players/ are never touched.
#
# Usage: pull.sh --scripts-dir DIR [--recover] [--force] [--dry-run]
#   --recover  repair an interrupted swap and restart the server if this script
#              stopped it (wired to ExecStopPost=).
#   --force    apply the snapshot even if it was already applied, and accept one
#              that looks much smaller than the current mirror.
#   --dry-run  fetch the manifest and run every check, change nothing.
set -Eeuo pipefail
umask 027

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

MODE=pull
FORCE=0
DRY_RUN=0
while (($#)); do
  case "$1" in
    --scripts-dir) MIRROR_SCRIPTS_DIR="$2"; shift 2 ;;
    --recover) MODE=recover; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mirror_load
mirror_require target

SYNC_ROOT="$MIRROR_SYNC_ROOT"
CACHE="$SYNC_ROOT/cache"
INCOMING="$SYNC_ROOT/incoming"
ROLLBACK="$SYNC_ROOT/rollback"
FAILED="$SYNC_ROOT/failed"
SWAP_JOURNAL="$SYNC_ROOT/SWAP_IN_PROGRESS"
STOPPED_MARKER="$SYNC_ROOT/STOPPED_BY_SYNC"
APPLIED="$SYNC_ROOT/APPLIED"
WORLD=""
PULL_EXTRAS=""
PULL_MODS=0
WAS_RUNNING=1
CACHE_CAP=0

validate_config() {
  local v
  [[ -n "$MIRROR_REMOTE" ]] || mirror_die "$EX_CONFIG" "MIRROR_REMOTE is not set (user@host of the source)"
  mirror_validate_dims
  mirror_validate_extras
  for v in "$MIRROR_SSH_KEY" "$MIRROR_KNOWN_HOSTS" "$SYNC_ROOT" "$SERVER_DIR"; do
    [[ "$v" != *[[:space:]]* ]] || mirror_die "$EX_CONFIG" "paths must not contain whitespace: $v"
  done
  [[ -r "$MIRROR_SSH_KEY" ]] || mirror_die "$EX_CONFIG" "SSH key not readable: $MIRROR_SSH_KEY"
  [[ -s "$MIRROR_KNOWN_HOSTS" ]] || mirror_die "$EX_CONFIG" "pinned known_hosts missing: $MIRROR_KNOWN_HOSTS (run mirror.sh pin-host)"
  case "$(realpath -m "$SYNC_ROOT")/" in
    "$(realpath -m "$SERVER_DIR")"/*) mirror_die "$EX_CONFIG" "the sync folder must live outside the server folder (backups would pick it up)" ;;
  esac
  mkdir -p "$CACHE" "$INCOMING" "$FAILED"
  [[ "$(stat -c %d "$SYNC_ROOT")" == "$(stat -c %d "$SERVER_DIR")" ]] ||
    mirror_die "$EX_CONFIG" "the sync folder and the server folder must be on the same filesystem so the swap is a rename"
  [[ -f "$WORLD/level.dat" ]] || mirror_die "$EX_CONFIG" "no level.dat in $WORLD; create the creative world first (mirror.sh setup target --prepare)"
}

ssh_cmd() {
  printf 'ssh -i %s -p %s -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4' \
    "$MIRROR_SSH_KEY" "$MIRROR_SSH_PORT" "$MIRROR_KNOWN_HOSTS"
}

# Retries only failures that a later attempt can fix (network, timeouts, ssh).
with_retries() {
  local n=1 rc
  while :; do
    rc=0
    "$@" || rc=$?
    case $rc in
      0) return 0 ;;
      10 | 12 | 30 | 35 | 255) ;;
      *) return "$rc" ;;
    esac
    ((n >= MIRROR_RETRIES)) && return "$rc"
    mirror_log WARN "attempt $n/$MIRROR_RETRIES failed (rc=$rc), retrying in ${MIRROR_RETRY_DELAY}s"
    sleep "$MIRROR_RETRY_DELAY"
    n=$((n + 1))
  done
}

fetch_manifest() {
  rsync -t --timeout="$MIRROR_RSYNC_TIMEOUT" -e "$(ssh_cmd)" "$MIRROR_REMOTE:LATEST" "$SYNC_ROOT/LATEST.remote"
}

# One rsync from the source's snapshot into the cache, with the cache watchdog:
# the manifest is only a claim. While the transfer runs, the cache may not grow
# past what the manifest declared (plus the cache's earlier content and a little
# slack); a source that sends more is stopped, not trusted to stop itself.
rsync_watched() { # <snapshot subpath> <cache dest> [extra rsync filters...]
  local sub=$1 dest=$2
  shift 2
  mkdir -p "$dest"
  rsync -rt --delete-delay --partial-dir=.rsync-partial \
    --timeout="$MIRROR_RSYNC_TIMEOUT" --bwlimit="$MIRROR_BWLIMIT_KIB" --max-size="$MIRROR_MAX_FILE_SIZE" -e "$(ssh_cmd)" \
    "$@" "$MIRROR_REMOTE:snapshots/$sub/" "$dest/" &
  local pid=$! rc=0
  while kill -0 "$pid" 2> /dev/null; do
    sleep 2
    if ((CACHE_CAP > 0)) && (($(du -sb "$CACHE" 2> /dev/null | cut -f1) > CACHE_CAP)); then
      kill "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      mirror_die 1 "the source is sending more than its manifest declared (the cache passed ${CACHE_CAP} bytes); the transfer was stopped and the server was not touched"
    fi
  done
  wait "$pid" || rc=$?
  return "$rc"
}

pull_dim() {
  local stamp=$1 dim=$2
  # Root-anchored filters: only the three chunk folders and region files in
  # them can ever reach the cache, whatever the export side contains.
  rsync_watched "$stamp/$dim" "$CACHE/$dim" \
    --include='/region/' --include='/entities/' --include='/poi/' \
    --include='/*/r.*.*.mca' --exclude='*'
}

pull_extra() { rsync_watched "$1/_extras/$2" "$CACHE/_extras/$2"; }

pull_mods() { rsync_watched "$1/_mods" "$CACHE/_mods" --include='/*.jar' --exclude='*'; }

server_active() {
  systemctl is-active --quiet "$INSTANCE_NAME.service" 2> /dev/null || session_running
}

say() { send_command "/say $1" > /dev/null 2>&1 || true; }

stop_server() {
  if ! server_active; then
    mirror_log INFO "the server is stopped; it will stay stopped after the swap"
    WAS_RUNNING=0
    return 0
  fi
  WAS_RUNNING=1
CACHE_CAP=0
  if ((MIRROR_WARN_SECONDS > 10)); then
    say "Mirror world refresh: server restarts in ${MIRROR_WARN_SECONDS} seconds."
    sleep $((MIRROR_WARN_SECONDS - 10))
  fi
  say "Mirror world refresh: restarting in 10 seconds."
  sleep "${MIRROR_STOP_GRACE:-10}"
  : > "$STOPPED_MARKER"
  # shellcheck disable=SC2086  # the stop command is a command line on purpose
  $MIRROR_STOP_CMD || mirror_die 1 "stop command failed: $MIRROR_STOP_CMD"
  local i
  for ((i = 0; i < MIRROR_STOP_TIMEOUT; i += 2)); do
    server_active || { mirror_log INFO "the server stopped"; return 0; }
    sleep 2
  done
  mirror_die 1 "the server is still running after ${MIRROR_STOP_TIMEOUT}s; nothing was swapped"
}

start_server() {
  local off i
  off="$(_log_size)"
  # shellcheck disable=SC2086
  $MIRROR_START_CMD || return 1
  for ((i = 0; i < MIRROR_START_TIMEOUT; i++)); do
    if _log_has_since "$off" "$MIRROR_DONE_RE"; then
      rm -f "$STOPPED_MARKER"
      return 0
    fi
    sleep 1
  done
  return 1
}

dim_path() { printf '%s/dimensions/%s/%s\n' "$WORLD" "$1" "$2"; }

# Puts the rollback copies of the extra folders and the mods folder back. The
# rejected ones go to the given failed folder for analysis.
restore_aux() { # <failed dir>
  local name live
  for name in $MIRROR_EXTRAS; do
    [[ -d "$ROLLBACK/_extras/$name" ]] || continue
    live="$WORLD/$name"
    if [[ -d "$live" ]]; then
      mkdir -p "$1/_extras"
      mv -T -- "$live" "$1/_extras/$name"
    fi
    mv -T -- "$ROLLBACK/_extras/$name" "$live"
  done
  if [[ -d "$ROLLBACK/_mods" ]]; then
    if [[ -d "$SERVER_DIR/mods" ]]; then
      mkdir -p "$1"
      mv -T -- "$SERVER_DIR/mods" "$1/_mods"
    fi
    mv -T -- "$ROLLBACK/_mods" "$SERVER_DIR/mods"
  fi
}

# Builds the mods folder to swap in: the source's jars (minus MIRROR_MODS_EXCLUDE)
# plus this server's own jars that match MIRROR_KEEP_MODS, unless the source has
# its own build of that mod. mods/disabled stays as it is.
stage_mods() {
  local jar alt dest="$INCOMING/_mods"
  mkdir -p "$dest"
  for jar in "$CACHE/_mods"/*.jar; do
    [[ -f "$jar" && ! -L "$jar" ]] || continue
    # A file name from the source becomes a path here: plain jar names only.
    [[ "$(basename "$jar")" =~ ^[A-Za-z0-9._+\ -]+\.jar$ ]] || mirror_die 1 "the source sent a mod with an unexpected file name; nothing was changed"
    if [[ -n "$MIRROR_MODS_EXCLUDE" ]] && grep -qiE "$MIRROR_MODS_EXCLUDE" <<< "$(basename "$jar")"; then continue; fi
    cp -a --reflink=auto -- "$jar" "$dest/"
  done
  local -a alts
  IFS='|' read -ra alts <<< "$MIRROR_KEEP_MODS"
  for alt in "${alts[@]}"; do
    [[ -n "$alt" ]] || continue
    if find "$dest" -maxdepth 1 -name '*.jar' -printf '%f\n' | grep -qiE -- "$alt"; then continue; fi
    for jar in "$SERVER_DIR/mods"/*.jar; do
      [[ -f "$jar" ]] || continue
      if grep -qiE -- "$alt" <<< "$(basename "$jar")"; then cp -a --reflink=auto -- "$jar" "$dest/"; fi
    done
  done
  [[ ! -d "$SERVER_DIR/mods/disabled" ]] || cp -a --reflink=auto -- "$SERVER_DIR/mods/disabled" "$dest/disabled"
}

# Moves the live chunk folders aside and the pre-staged ones in. Every step is
# a rename on one filesystem; the journal lets --recover undo a partial swap.
swap_in() {
  local dim d live
  : > "$SWAP_JOURNAL"
  for dim in $MIRROR_DIMS; do
    mkdir -p "$ROLLBACK/$dim" "$WORLD/dimensions/$dim"
    for d in $CHUNK_DIRS; do
      [[ -d "$INCOMING/$dim/$d" ]] || continue
      live="$(dim_path "$dim" "$d")"
      [[ -d "$live" ]] && mv -T -- "$live" "$ROLLBACK/$dim/$d"
      mv -T -- "$INCOMING/$dim/$d" "$live"
    done
  done
  local name
  for name in $PULL_EXTRAS; do
    mkdir -p "$ROLLBACK/_extras"
    [[ -d "$WORLD/$name" ]] && mv -T -- "$WORLD/$name" "$ROLLBACK/_extras/$name"
    mv -T -- "$INCOMING/_extras/$name" "$WORLD/$name"
  done
  if ((PULL_MODS)); then
    [[ -d "$SERVER_DIR/mods" ]] && mv -T -- "$SERVER_DIR/mods" "$ROLLBACK/_mods"
    mv -T -- "$INCOMING/_mods" "$SERVER_DIR/mods"
  fi
  rm -f "$SWAP_JOURNAL"
}

# Puts the rollback copy back. The rejected data goes to $FAILED for analysis.
swap_back() {
  local tag=$1 dim d live
  : > "$SWAP_JOURNAL"
  for dim in $MIRROR_DIMS; do
    for d in $CHUNK_DIRS; do
      [[ -d "$ROLLBACK/$dim/$d" ]] || continue
      live="$(dim_path "$dim" "$d")"
      if [[ -d "$live" ]]; then
        mkdir -p "$FAILED/$tag/$dim"
        mv -T -- "$live" "$FAILED/$tag/$dim/$d"
      fi
      mv -T -- "$ROLLBACK/$dim/$d" "$live"
    done
  done
  restore_aux "$FAILED/$tag"
  rm -f "$SWAP_JOURNAL"
}

# A swap that was killed half way leaves some folders new and some old, which
# would pair new chunks with old entities and points of interest. Every folder
# that has a rollback copy is therefore put back, not only the missing ones; the
# half-applied folders are kept under failed/recover.
recover() {
  local dim d live repaired=0
  if [[ -e "$SWAP_JOURNAL" ]]; then
    mirror_log WARN "an interrupted swap was found; putting the previous chunk folders back"
    for dim in $MIRROR_DIMS; do
      for d in $CHUNK_DIRS; do
        live="$(dim_path "$dim" "$d")"
        if [[ -d "$ROLLBACK/$dim/$d" ]]; then
          if [[ -d "$live" ]]; then
            mkdir -p "$FAILED/recover/$dim"
            mv -T -- "$live" "$FAILED/recover/$dim/$d"
          fi
          mv -T -- "$ROLLBACK/$dim/$d" "$live"
          repaired=1
        fi
      done
    done
    restore_aux "$FAILED/recover"
    rm -f "$SWAP_JOURNAL"
  fi
  if [[ -e "$STOPPED_MARKER" ]] && ! server_active; then
    mirror_log WARN "the server was stopped by an interrupted sync, starting it"
    if start_server; then
      mirror_notify mirror_sync_complete "recovered: the server was restarted after an interrupted sync (repaired=$repaired)"
    else
      mirror_notify mirror_sync_failed "RECOVERY FAILED: the server did not start, check it by hand"
      return 1
    fi
  fi
  return 0
}

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ "$MODE" == pull ]] && ((DRY_RUN == 0)); then
    recover || true
    ((rc == EX_LOCKED)) || mirror_notify mirror_sync_failed "sync FAILED (rc=$rc): ${FAIL_REASON:-see journal}"
  fi
  exit "$rc"
}

# Worldgen parity: the same Minecraft version is required (a 26.3 world cannot
# be read by an older server); a different Fabric Loader or worldgen mod set only
# changes chunks generated later, so it is a warning unless MIRROR_PARITY=refuse.
check_parity() {
  local m=$1 rv lv rl ll rm lm
  rv="$(mirror_manifest_get mc_version "$m")"
  lv="$(mirror_mc_version)"
  if [[ "$rv" != "$lv" ]]; then
    if [[ "$MIRROR_REQUIRE_SAME_VERSION" == true ]]; then
      mirror_die "$EX_STALE" "version mismatch: source ${rv:-unknown}, this server ${lv:-unknown}"
    fi
    mirror_log WARN "version mismatch: source ${rv:-unknown}, this server ${lv:-unknown}"
  fi
  [[ "$MIRROR_PARITY" != off ]] || return 0
  rl="$(mirror_manifest_get loader "$m")"
  ll="$(mirror_loader_version)"
  rm="$(mirror_manifest_get worldgen_mods "$m")"
  lm="$(mirror_worldgen_mods)"
  local problem=""
  [[ -z "$rl" || "$rl" == "$ll" ]] || problem+="Fabric Loader differs (source $rl, here $ll). "
  # When this run takes the source's mods, this server runs them after the swap, so
  # only the ones left out on purpose (MIRROR_MODS_EXCLUDE) can still differ.
  if ((PULL_MODS)); then
    local left_out=""
    if [[ -n "$MIRROR_MODS_EXCLUDE" && "$rm" != none ]]; then
      left_out="$(tr '|' '\n' <<< "$rm" | grep -iE -- "$MIRROR_MODS_EXCLUDE" | paste -sd ' ' -)" || left_out=""
    fi
    [[ -z "$left_out" ]] || problem+="world-generation mods of the source are not installed here on purpose ($left_out). "
    rm=""
  fi
  [[ -z "$rm" || "$rm" == "$lm" ]] || problem+="worldgen mods differ (source: $rm; here: $lm). "
  [[ -z "$problem" ]] && return 0
  if [[ "$MIRROR_PARITY" == refuse ]]; then
    mirror_die "$EX_STALE" "${problem}Chunks generated later will not match the source (MIRROR_PARITY=refuse)."
  fi
  mirror_log WARN "${problem}Chunks generated later will not match the source."
}

# A snapshot with no region files, or far fewer than the current mirror, is
# more likely a fresh or wiped source world than a real change.
check_shrink() {
  local dim live_n new_n
  for dim in $MIRROR_DIMS; do
    new_n="$(find "$CACHE/$dim/region" -maxdepth 1 -type f -name 'r.*.*.mca' 2> /dev/null | wc -l | tr -d '[:space:]')"
    live_n="$(find "$(dim_path "$dim" region)" -maxdepth 1 -type f -name 'r.*.*.mca' 2> /dev/null | wc -l | tr -d '[:space:]')"
    if ((new_n == 0)); then
      mirror_die "$EX_STALE" "the snapshot has no region files for $dim; refusing to replace the mirror with nothing"
    fi
    if ((FORCE == 0 && live_n > 0 && new_n * 100 < live_n * MIRROR_MIN_REGION_RATIO_PCT)); then
      mirror_die "$EX_STALE" "the snapshot has $new_n region files for $dim, the mirror has $live_n (limit ${MIRROR_MIN_REGION_RATIO_PCT}%). Use --force if the source world really shrank."
    fi
  done
}

main() {
  WORLD="$SERVER_DIR/$(mirror_level_name)"
  mkdir -p "$SYNC_ROOT"
  exec 9>> "$SYNC_ROOT/.pull.lock"
  flock -n 9 || { mirror_log WARN "another sync holds the lock"; exit "$EX_LOCKED"; }

  if [[ "$MODE" == recover ]]; then
    recover
    exit $?
  fi

  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  validate_config
  ((DRY_RUN)) || recover

  mirror_log INFO "fetching manifest from $MIRROR_REMOTE"
  with_retries fetch_manifest || mirror_die "$EX_UNAVAILABLE" "could not fetch LATEST from $MIRROR_REMOTE (rc=$?)"
  local m="$SYNC_ROOT/LATEST.remote" stamp created age dims files bytes dim seed lseed
  stamp="$(mirror_manifest_get snapshot "$m")"
  [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || mirror_die "$EX_STALE" "the manifest has no valid snapshot id"
  created="$(mirror_manifest_get created_epoch "$m")"
  # Canonical decimal only: a leading zero would be read as octal by the shell.
  [[ "$created" =~ ^(0|[1-9][0-9]*)$ ]] || mirror_die "$EX_STALE" "the manifest has no valid created_epoch"
  age=$((($(date +%s) - created) / 3600))
  ((age <= MIRROR_MAX_SNAPSHOT_AGE_H)) || mirror_die "$EX_STALE" "snapshot $stamp is ${age}h old (limit ${MIRROR_MAX_SNAPSHOT_AGE_H}h); is the export timer running?"
  dims=" $(mirror_manifest_get dims "$m") "
  for dim in $MIRROR_DIMS; do
    [[ "$dims" == *" $dim "* ]] || mirror_die "$EX_STALE" "snapshot $stamp does not contain $dim"
  done
  if ((FORCE == 0)) && [[ -r "$APPLIED" && "$(cat "$APPLIED")" == "$stamp" ]]; then
    mirror_log INFO "snapshot $stamp already applied, nothing to do"
    exit 0
  fi
  # The extra folders and the mods this run takes from the snapshot: only what is
  # configured here and also offered there (the source never decides on its own).
  local name xs mods_n aux_mb=0
  PULL_EXTRAS="" PULL_MODS=0
  xs=" $(mirror_manifest_get extras "$m") "
  for name in $MIRROR_EXTRAS; do
    if [[ "$xs" == *" $name "* ]]; then
      PULL_EXTRAS+="${PULL_EXTRAS:+ }$name"
      aux_mb=$((aux_mb + MIRROR_EXTRAS_MAX_MB))
    else
      mirror_log WARN "the snapshot has no extra folder $name; it is left as it is"
    fi
  done
  if [[ "$MIRROR_SYNC_MODS" == true ]]; then
    mods_n="$(mirror_manifest_get mods "$m")"
    if [[ "$mods_n" =~ ^[1-9][0-9]{0,3}$ ]]; then
      PULL_MODS=1
      aux_mb=$((aux_mb + MIRROR_MODS_MAX_MB))
    else
      mirror_log WARN "the snapshot carries no mods (is MIRROR_EXPORT_MODS off there?); this server's mods are left as they are"
    fi
  fi

  check_parity "$m"
  seed="$(mirror_manifest_get level_seed "$m")"
  lseed="$(mirror_level_seed)"
  if [[ -n "$seed" && "$seed" != unknown && "$lseed" != unknown && "$seed" != "$lseed" ]]; then
    mirror_log WARN "level-seed differs (source $seed, this server $lseed); chunks generated later will not continue the mirrored terrain"
  fi
  files="$(mirror_manifest_get files "$m")"
  bytes="$(mirror_manifest_get bytes "$m")"
  [[ "$files" =~ ^(0|[1-9][0-9]*)$ && "$bytes" =~ ^(0|[1-9][0-9]*)$ ]] || mirror_die "$EX_STALE" "the manifest lacks valid files/bytes"
  # More digits than these would wrap around in the shell arithmetic below and
  # could make a huge snapshot look small to the space check.
  ((${#files} <= 9 && ${#bytes} <= 15)) || mirror_die "$EX_STALE" "the manifest sizes are not plausible (files=$files bytes=$bytes)"
  if ((MIRROR_MAX_SNAPSHOT_GB > 0 && bytes > MIRROR_MAX_SNAPSHOT_GB * 1024 * 1024 * 1024)); then
    mirror_die "$EX_STALE" "the snapshot is $((bytes / 1073741824)) GiB, over MIRROR_MAX_SNAPSHOT_GB=$MIRROR_MAX_SNAPSHOT_GB"
  fi

  # Space is checked before anything is deleted. The previous rollback is last
  # night's mirror and worthless once a new snapshot is due, so it counts as
  # free; if the snapshot only fits after it is dropped, it is dropped, and if it
  # does not fit even then nothing was touched.
  local cache_bytes avail need rb_bytes
  read -r _ cache_bytes < <(mirror_tree_stats "$CACHE")
  avail="$(mirror_avail_bytes "$SYNC_ROOT")"
  rb_bytes="$(du -sb "$ROLLBACK" 2> /dev/null | cut -f1)" || rb_bytes=0
  need=$((bytes + (bytes > cache_bytes ? bytes - cache_bytes : 0) + (${MIRROR_SPACE_MARGIN_MB:-4096} + aux_mb) * 1024 * 1024))
  ((avail + ${rb_bytes:-0} >= need)) ||
    mirror_die "$EX_NOSPACE" "need ~$((need / 1048576)) MiB in $SYNC_ROOT, have $((avail / 1048576)) MiB (plus $((${rb_bytes:-0} / 1048576)) MiB of old rollback); nothing was changed"

  if ((DRY_RUN)); then
    mirror_log INFO "dry run: snapshot $stamp ($files files, $((bytes / 1048576)) MiB) would be pulled and applied"
    exit 0
  fi

  rm -rf -- "$ROLLBACK" "${INCOMING:?}"/*
  mirror_log INFO "pulling snapshot $stamp ($files files, $((bytes / 1048576)) MiB)"
  : > "$CACHE/.INCOMPLETE"
  CACHE_CAP=$(($(du -sb "$CACHE" | cut -f1) + bytes + (${MIRROR_TRANSFER_SLACK_MB:-256} + aux_mb) * 1048576))
  for dim in $MIRROR_DIMS; do
    with_retries pull_dim "$stamp" "$dim" || mirror_die 1 "rsync of $dim failed (rc=$?); the server was not touched"
  done
  local got_files got_bytes paths=()
  for dim in $MIRROR_DIMS; do paths+=("$CACHE/$dim"); done
  read -r got_files got_bytes < <(mirror_tree_stats "${paths[@]}")
  if [[ "$got_files" != "$files" || "$got_bytes" != "$bytes" ]]; then
    mirror_die 1 "the cache does not match the manifest: got $got_files files/$got_bytes B, expected $files/$bytes"
  fi
  for name in $PULL_EXTRAS; do
    with_retries pull_extra "$stamp" "$name" || mirror_die 1 "rsync of the extra folder $name failed (rc=$?); the server was not touched"
  done
  if ((PULL_MODS)); then
    with_retries pull_mods "$stamp" || mirror_die 1 "rsync of the mods failed (rc=$?); the server was not touched"
    got_files="$(find "$CACHE/_mods" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d '[:space:]')"
    [[ "$got_files" == "$mods_n" ]] || mirror_die 1 "the cache has $got_files mods, the manifest says $mods_n; the server was not touched"
  fi
  cp -- "$m" "$CACHE/MANIFEST"
  rm -f "$CACHE/.INCOMPLETE"

  check_shrink

  # The instance's operation lock is taken only now, so a long transfer never
  # blocks its backups; once held, no backup, restore or rollback runs.
  mirror_take_operation_lock mirror-pull

  mirror_log INFO "pre-staging a copy next to the world"
  local d
  for dim in $MIRROR_DIMS; do
    for d in $CHUNK_DIRS; do
      [[ -d "$CACHE/$dim/$d" ]] || continue
      mkdir -p "$INCOMING/$dim"
      cp -a --reflink=auto -- "$CACHE/$dim/$d" "$INCOMING/$dim/$d"
      rm -rf -- "$INCOMING/$dim/$d/.rsync-partial"
    done
  done

  for name in $PULL_EXTRAS; do
    mkdir -p "$INCOMING/_extras"
    cp -a --reflink=auto -- "$CACHE/_extras/$name" "$INCOMING/_extras/$name"
    rm -rf -- "$INCOMING/_extras/$name/.rsync-partial"
  done
  ((PULL_MODS == 0)) || stage_mods

  stop_server
  mirror_log INFO "swapping mirrored dimensions: $MIRROR_DIMS${PULL_EXTRAS:+ and the folders $PULL_EXTRAS}$( ((PULL_MODS)) && echo ' and the mods')"
  swap_in
  if ((WAS_RUNNING == 0)); then
    printf '%s\n' "$stamp" > "$APPLIED"
    mirror_log SUCCESS "applied snapshot $stamp (server left stopped, not start-tested)"
    exit 0
  fi
  if start_server; then
    printf '%s\n' "$stamp" > "$APPLIED"
    find "$FAILED" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf -- {} +
    mirror_log SUCCESS "applied snapshot $stamp"
    mirror_notify mirror_sync_complete "mirror refreshed to snapshot $stamp"
    exit 0
  fi

  mirror_log ERROR "the server did not come up with snapshot $stamp, rolling back"
  # shellcheck disable=SC2086
  $MIRROR_STOP_CMD || true
  local i
  for ((i = 0; i < MIRROR_STOP_TIMEOUT; i += 2)); do server_active || break; sleep 2; done
  swap_back "$stamp"
  if start_server; then
    mirror_die 1 "snapshot $stamp was rejected and rolled back; the rejected data is in $FAILED/$stamp"
  fi
  mirror_die 1 "rolled back, but the server still does not start; check it by hand"
}

main
