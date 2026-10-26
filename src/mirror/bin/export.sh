#!/bin/bash
# Mirror export: runs on the source (survival) server as the server owner.
# Publishes an immutable snapshot of the mirrored dimensions' chunk folders under
# <mirror state>/export/snapshots/<stamp>/ and the manifest of the newest one as
# <export>/LATEST. The creative server pulls it read-only through rrsync; nothing
# here talks to it.
#
# Usage: export.sh --scripts-dir DIR [--ensure-save-on]
#   --ensure-save-on  only re-enable saving if a previous run died inside the
#                     save-off window (wired to ExecStopPost=).
set -Eeuo pipefail
umask 027

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

MODE=run
while (($#)); do
  case "$1" in
    --scripts-dir) MIRROR_SCRIPTS_DIR="$2"; shift 2 ;;
    --ensure-save-on) MODE=ensure-save-on; shift ;;
    -h | --help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mirror_load
mirror_require source

EXPORT_ROOT="$MIRROR_EXPORT_ROOT"
SNAP_DIR="$EXPORT_ROOT/snapshots"
SAVE_OFF_MARKER="$EXPORT_ROOT/.save-off-active"
SAVE_OFF=0
TMP_SNAP=""

space_preflight() {
  local world=$1 prev=$2 need avail est dim size
  est=0
  if [[ -n "$prev" && -r "$prev/MANIFEST" ]]; then
    est="$(mirror_manifest_get bytes "$prev/MANIFEST")"
  fi
  if [[ -z "$est" || "$est" == 0 ]]; then
    est=0
    for dim in $MIRROR_DIMS; do
      size="$(du -sb "$world/dimensions/$dim" 2> /dev/null | cut -f1)" || size=0
      est=$((est + ${size:-0}))
    done
  fi
  need=$((est + ${MIRROR_SPACE_MARGIN_MB:-2048} * 1024 * 1024))
  avail="$(mirror_avail_bytes "$EXPORT_ROOT")"
  ((avail >= need)) || mirror_die "$EX_NOSPACE" "need ~$((need / 1048576)) MiB on $EXPORT_ROOT, have $((avail / 1048576)) MiB"
}

save_on() {
  ((SAVE_OFF)) || return 0
  if enable_auto_save > /dev/null 2>&1; then
    rm -f "$SAVE_OFF_MARKER"
    SAVE_OFF=0
    mirror_log INFO "saving re-enabled"
  else
    mirror_log ERROR "could not send save-on; run it manually"
  fi
}

on_exit() {
  local rc=$?
  save_on
  [[ -n "$TMP_SNAP" && -d "$TMP_SNAP" ]] && rm -rf -- "$TMP_SNAP"
  if ((rc != 0 && rc != EX_LOCKED)); then
    mirror_notify mirror_export_failed "export FAILED (rc=$rc): ${FAIL_REASON:-see journal}"
  fi
  exit "$rc"
}

# A save-off window is one the previous run opened and never closed (killed
# without its trap, for example). Callers hold the operation lock, so no other
# export can be inside one.
recover_save_off() {
  [[ -e "$SAVE_OFF_MARKER" ]] || return 0
  if ! server_reachable; then
    # save-off does not survive a restart, so a stopped server needs nothing.
    rm -f "$SAVE_OFF_MARKER"
    return 0
  fi
  mirror_log WARN "a previous export died inside the save-off window; re-enabling saving"
  SAVE_OFF=1
  save_on
  ((SAVE_OFF == 0)) || return 1
  mirror_notify mirror_export_failed "recovered: saving re-enabled after an interrupted export"
}

latest_snapshot() {
  local f
  f="$(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}T[0-9]{6}Z' -printf '%f\n' 2> /dev/null | sort | tail -n 1)" || true
  [[ -n "$f" ]] && printf '%s\n' "$SNAP_DIR/$f"
  return 0
}

copy_dims() {
  local world=$1 prev=$2 dim d rc
  local -a link
  for dim in $MIRROR_DIMS; do
    for d in $CHUNK_DIRS; do
      if [[ ! -d "$world/dimensions/$dim/$d" ]]; then
        mirror_log WARN "missing $world/dimensions/$dim/$d, skipped"
        continue
      fi
      mkdir -p "$TMP_SNAP/$dim/$d"
      link=()
      [[ -n "$prev" && -d "$prev/$dim/$d" ]] && link=("--link-dest=$prev/$dim/$d")
      rc=0
      timeout "$MIRROR_SAVE_OFF_MAX" nice -n 10 ionice -c2 -n7 \
        rsync -rt --chmod=D2750,F640 "${link[@]}" \
        --include='r.*.*.mca' --exclude='*' \
        -- "$world/dimensions/$dim/$d/" "$TMP_SNAP/$dim/$d/" || rc=$?
      case $rc in
        0) ;;
        24) mirror_log WARN "rsync: files vanished in $dim/$d (rc=24), continuing" ;;
        124) mirror_die 1 "copy of $dim/$d exceeded MIRROR_SAVE_OFF_MAX=${MIRROR_SAVE_OFF_MAX}s" ;;
        *) mirror_die 1 "rsync failed for $dim/$d (rc=$rc)" ;;
      esac
    done
  done
}

EXTRAS_COPIED=""
MODS_COPIED=0

# World folders listed in MIRROR_EXTRAS (homes and the like), copied whole into
# the snapshot's _extras. They are small, so they are bounded instead of linked.
copy_extras() {
  local world=$1 name mb rc
  EXTRAS_COPIED=""
  for name in $MIRROR_EXTRAS; do
    if [[ ! -d "$world/$name" ]]; then
      mirror_log WARN "extra folder $name does not exist in the world, skipped"
      continue
    fi
    mb=$(($(du -sk "$world/$name" 2> /dev/null | cut -f1) / 1024))
    ((mb <= MIRROR_EXTRAS_MAX_MB)) || mirror_die 1 "extra folder $name is ${mb} MiB, over MIRROR_EXTRAS_MAX_MB=$MIRROR_EXTRAS_MAX_MB"
    mkdir -p "$TMP_SNAP/_extras/$name"
    rc=0
    timeout "$MIRROR_SAVE_OFF_MAX" rsync -rt --chmod=D2750,F640 -- "$world/$name/" "$TMP_SNAP/_extras/$name/" || rc=$?
    case $rc in
      0 | 24) ;;
      *) mirror_die 1 "rsync failed for extra folder $name (rc=$rc)" ;;
    esac
    EXTRAS_COPIED+="${EXTRAS_COPIED:+ }$name"
  done
}

# The jars of the server's mods folder (not mods/disabled), so a target can run
# the same mods. Linked to the previous snapshot, so unchanged jars cost nothing.
copy_mods() {
  local prev=$1 mb rc
  local -a link=()
  MODS_COPIED=0
  [[ "$MIRROR_EXPORT_MODS" == true && -d "$SERVER_DIR/mods" ]] || return 0
  mb=$(($(find "$SERVER_DIR/mods" -maxdepth 1 -type f -name '*.jar' -printf '%s\n' | awk '{s += $1} END {print s + 0}') / 1048576))
  ((mb <= MIRROR_MODS_MAX_MB)) || mirror_die 1 "the mods folder is ${mb} MiB, over MIRROR_MODS_MAX_MB=$MIRROR_MODS_MAX_MB"
  mkdir -p "$TMP_SNAP/_mods"
  [[ -n "$prev" && -d "$prev/_mods" ]] && link=("--link-dest=$prev/_mods")
  rc=0
  rsync -rt --chmod=D2750,F640 "${link[@]}" --include='/*.jar' --exclude='*' -- "$SERVER_DIR/mods/" "$TMP_SNAP/_mods/" || rc=$?
  case $rc in
    0 | 24) ;;
    *) mirror_die 1 "rsync failed for the mods folder (rc=$rc)" ;;
  esac
  MODS_COPIED="$(find "$TMP_SNAP/_mods" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d '[:space:]')"
}

write_manifest() {
  local stamp=$1 files bytes version
  files="$(find "$TMP_SNAP" -type f -name 'r.*.*.mca' | wc -l | tr -d '[:space:]')"
  bytes="$(find "$TMP_SNAP" -type f -name 'r.*.*.mca' -printf '%s\n' | awk '{s += $1} END {print s + 0}')"
  version="$(mirror_mc_version)"
  {
    echo "format=2"
    echo "snapshot=$stamp"
    echo "created_epoch=$(date +%s)"
    echo "source_mode=$MIRROR_SOURCE_MODE"
    echo "mc_version=$version"
    echo "loader=$(mirror_loader_version)"
    echo "worldgen_mods=$(mirror_worldgen_mods)"
    echo "level_seed=$(mirror_level_seed)"
    echo "dims=$MIRROR_DIMS"
    echo "extras=$EXTRAS_COPIED"
    echo "mods=$MODS_COPIED"
    echo "files=$files"
    echo "bytes=$bytes"
  } > "$TMP_SNAP/MANIFEST"
  mirror_log INFO "snapshot $stamp: $files region files, $((bytes / 1048576)) MiB, mc $version"
}

publish() {
  local stamp=$1 tmp
  mv -T -- "$TMP_SNAP" "$SNAP_DIR/$stamp"
  TMP_SNAP=""
  tmp="$EXPORT_ROOT/.LATEST.$$"
  cp -- "$SNAP_DIR/$stamp/MANIFEST" "$tmp"
  chmod 640 "$tmp"
  mv -f -- "$tmp" "$EXPORT_ROOT/LATEST"
}

prune() {
  local keep=$1 old
  find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}T[0-9]{6}Z' -printf '%f\n' | sort | head -n "-$keep" |
    while IFS= read -r old; do
      mirror_log INFO "pruning snapshot $old"
      rm -rf -- "${SNAP_DIR:?}/$old"
    done
}

# Sets STAGE_WORLD to the world to copy from in stage mode: the backup's
# persistent staging mirror, which the backup refreshed (and flushed) itself, so
# no save-off window is needed. Not a $(...) function, so a refusal keeps its reason.
stage_world() {
  local level=$1 stage marker stamp_file
  stage="$BACKUPS_PATH/.stage/mirror"
  marker="$BACKUPS_PATH/.stage/MIRROR_INCOMPLETE"
  stamp_file="$BACKUPS_PATH/.meta/last_backup.json"
  [[ -d "$stage/$level/dimensions" ]] || mirror_die "$EX_UNAVAILABLE" "no staged world at $stage/$level (is BACKUP_STAGING_MODE=mirror?)"
  [[ ! -e "$marker" ]] || mirror_die "$EX_UNAVAILABLE" "the staging copy is marked incomplete: $marker"
  if [[ -n "$(find "$stamp_file" -mmin "+$MIRROR_STAGE_MAX_AGE_MIN" 2> /dev/null)" || ! -e "$stamp_file" ]]; then
    mirror_die "$EX_UNAVAILABLE" "the staging copy is older than ${MIRROR_STAGE_MAX_AGE_MIN} min ($stamp_file)"
  fi
  STAGE_WORLD="$stage/$level"
}

main() {
  [[ "$MIRROR_SOURCE_MODE" == live || "$MIRROR_SOURCE_MODE" == stage ]] || mirror_die "$EX_CONFIG" "MIRROR_SOURCE_MODE must be live or stage"
  if [[ "$MODE" == ensure-save-on ]]; then
    recover_save_off || exit 1
    exit 0
  fi

  mirror_validate_dims
  mirror_validate_extras
  if [[ ! "$MIRROR_KEEP_SNAPSHOTS" =~ ^[0-9]+$ ]] || ((MIRROR_KEEP_SNAPSHOTS < 2)); then
    mirror_die "$EX_CONFIG" "MIRROR_KEEP_SNAPSHOTS must be >= 2 so a pull in progress never loses its snapshot"
  fi
  mkdir -p "$SNAP_DIR"
  chmod 2750 "$EXPORT_ROOT" "$SNAP_DIR" 2> /dev/null || true
  # The read-only account reads the snapshots through the export folder's group. A
  # recursive chown by an admin or a restore would reset it, and the pull would
  # then fail with "permission denied", so every run puts the group back.
  local group
  group="$(stat -c %G "$EXPORT_ROOT" 2> /dev/null || true)"
  if [[ -n "$group" && "$group" != UNKNOWN ]]; then
    find "$SNAP_DIR" ! -group "$group" -exec chgrp "$group" {} + 2> /dev/null || true
  fi

  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  mirror_take_operation_lock mirror-export
  recover_save_off || mirror_die 1 "could not re-enable saving after an earlier interrupted export"

  local level world prev stamp
  level="$(mirror_level_name)"
  prev="$(latest_snapshot)"
  # A second export within the same second (a manual run after the timer's) must
  # not collide with the snapshot just published: take the next free second.
  local ts
  ts="$(date -u +%s)"
  stamp="$(date -u -d "@$ts" +%Y%m%dT%H%M%SZ)"
  while [[ -e "$SNAP_DIR/$stamp" ]]; do
    ts=$((ts + 1))
    stamp="$(date -u -d "@$ts" +%Y%m%dT%H%M%SZ)"
  done
  TMP_SNAP="$SNAP_DIR/.incoming.$stamp"
  rm -rf -- "$SNAP_DIR"/.incoming.*

  if [[ "$MIRROR_SOURCE_MODE" == stage ]]; then
    stage_world "$level"
    world="$STAGE_WORLD"
    space_preflight "$world" "$prev"
    copy_dims "$world" "$prev"
    copy_extras "$world"
  else
    world="$SERVER_DIR/$level"
    [[ -d "$world/dimensions" ]] || mirror_die "$EX_UNAVAILABLE" "no 26.x world layout at $world/dimensions"
    space_preflight "$world" "$prev"
    if server_reachable; then
      mirror_log INFO "server running: save-off, then a confirmed save-all flush"
      local t0=$SECONDS
      # The marker goes down first: if this run dies before save-on, the next run
      # (or ExecStopPost) finds it and repairs the window.
      : > "$SAVE_OFF_MARKER"
      SAVE_OFF=1
      disable_auto_save > /dev/null || mirror_die 1 "could not turn auto-save off"
      save_and_wait > /dev/null 2>&1 || mirror_die 1 "the server did not confirm the save; nothing was copied"
      copy_dims "$world" "$prev"
      copy_extras "$world"
      save_on
      mirror_log INFO "save-off window: $((SECONDS - t0))s"
    else
      mirror_log INFO "server stopped: copying without a save window"
      copy_dims "$world" "$prev"
      copy_extras "$world"
    fi
  fi

  copy_mods "$prev"
  write_manifest "$stamp"
  publish "$stamp"
  prune "$MIRROR_KEEP_SNAPSHOTS"
  mirror_log SUCCESS "published snapshot $stamp"
}

main
