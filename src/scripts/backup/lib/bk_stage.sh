#!/bin/bash
# Staging: the copy of the server tree that tar reads, made while auto-save is
# off. Three modes under $BACKUPS_PATH/.stage:
#   mirror   a persistent rsync mirror; after the first run only changed files
#            are copied, so the save-off window is seconds on an idle world
#   reflink  a per-run cp --reflink=always snapshot (XFS, btrfs), near instant
#   fresh    a per-run full copy, for disks with no room for a mirror
# Never hardlinks: region files are rewritten in place, so a hardlinked copy
# would change after save-on. Needs bk_common.sh, SERVER_PATH, BACKUPS_PATH.

if [[ -n "${_BK_STAGE_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_BK_STAGE_LOADED=1

BK_EXCLUDES=()
BK_STAGE_ROOT=""
BK_STAGE_SNAP=""
BK_STAGE_META=""

bk_stage_dir() { echo "$BACKUPS_PATH/.stage"; }
bk_stage_mirror_dir() { echo "$BACKUPS_PATH/.stage/mirror"; }
bk_stage_marker() { echo "$BACKUPS_PATH/.stage/MIRROR_INCOMPLETE"; }

# bk_stage_reflink_works: clones one small server file into .stage.
bk_stage_reflink_works() {
  local src probe
  src="$(find "$SERVER_PATH" -maxdepth 2 -type f -size -256k -print -quit 2>/dev/null)"
  [[ -n "$src" ]] || return 1
  mkdir -p "$(bk_stage_dir)" || return 1
  probe="$(bk_stage_dir)/.reflink-probe.$$"
  if cp --reflink=always -- "$src" "$probe" 2>/dev/null; then
    rm -f -- "$probe"
    return 0
  fi
  rm -f -- "$probe"
  return 1
}

# bk_stage_select: prints mirror|reflink|fresh from BACKUP_STAGING_MODE.
# A mirror is only used when .stage and the mirror are private to this user
# (bk_private_dir): a mirror another user can write to would carry planted
# content into the next archive, since the quick check skips files whose size
# and mtime are unchanged. Otherwise the run falls back to a fresh copy.
bk_stage_select() {
  local mode
  case "${BACKUP_STAGING_MODE:-auto}" in
    mirror|fresh) mode="$BACKUP_STAGING_MODE" ;;
    reflink)
      if bk_stage_reflink_works; then mode=reflink; else
        bk_log WARN "BACKUP_STAGING_MODE=reflink but the backups filesystem cannot clone server files; using mirror"
        mode=mirror
      fi ;;
    *) if bk_stage_reflink_works; then mode=reflink; else mode=mirror; fi ;;
  esac
  # Every mode stages under .stage, so a .stage that is not ours alone ends
  # the run rather than copying the server into it.
  bk_private_dir "$(bk_stage_dir)" >&2 || { bk_log ERROR "The staging folder $(bk_stage_dir) is not private to this user" >&2; return 1; }
  if [[ "$mode" == mirror ]] && ! bk_private_dir "$(bk_stage_mirror_dir)" >&2; then
    bk_log WARN "The staging mirror is not private to this user; using a fresh copy for this run" >&2
    mode=fresh
  fi
  echo "$mode"
}

# bk_stage_build_excludes: rsync patterns, unanchored on purpose (anchoring
# logs/* would start including plugin log folders). The backups folder and a
# leftover .mc-meta are anchored to the server root.
bk_stage_build_excludes() {
  BK_EXCLUDES=('/backups' '/.mc-meta' 'logs/*' '*.log' '*.tmp' 'crash-reports/*' '*.gz' 'ledger.sqlite')
  local pat
  for pat in ${BACKUP_EXTRA_EXCLUDES:-}; do
    BK_EXCLUDES+=("$pat")
  done
}

# bk_stage_top_level_symlinks: top-level entries that are symlinks, with their
# targets, one "name -> target" per line.
bk_stage_top_level_symlinks() {
  local item
  ( cd "$SERVER_PATH" && for item in * .*; do
      [[ "$item" == "." || "$item" == ".." ]] && continue
      [[ -L "$item" ]] && printf '%s -> %s\n' "$item" "$(readlink -- "$item")"
    done; true )
}

_bk_rsync_excludes() {
  local pat
  for pat in "${BK_EXCLUDES[@]}"; do printf -- '--exclude=%s\n' "$pat"; done
}

# bk_stage_refresh <mode> <server_dir> <full 0|1>
# Leaves the staging root in BK_STAGE_ROOT. On an archive run (<full>=1) the mirror is compared
# by checksum rather than size and mtime, because a region file rewritten in
# the same second as the previous mirror copy, with the same sector-padded
# size, would otherwise be skipped.
bk_stage_refresh() {
  local mode="$1" server="$2" full="${3:-0}" root rc=0
  BK_STAGE_ROOT=""
  local -a ex
  bk_stage_build_excludes
  mapfile -t ex < <(_bk_rsync_excludes)
  [[ "${BK_VERBOSE:-false}" == true ]] && ex+=(-v --stats)
  local -a links=()
  mapfile -t links < <(bk_stage_top_level_symlinks)
  local l
  for l in "${links[@]}"; do
    [[ -n "$l" ]] || continue
    if [[ "${BACKUP_FOLLOW_SYMLINKS:-true}" == true ]]; then
      bk_log INFO "Following top-level symlink $l"
    else
      bk_log WARN "Top-level symlink $l is archived as a link (BACKUP_FOLLOW_SYMLINKS=false)"
    fi
  done
  local -a follow=()
  [[ "${BACKUP_FOLLOW_SYMLINKS:-true}" == true ]] && follow=(--copy-unsafe-links)

  case "$mode" in
    mirror)
      root="$(bk_stage_mirror_dir)"
      mkdir -p "$root" || return 1
      local -a verify=()
      [[ "$full" == 1 ]] && verify=(--checksum)
      : > "$(bk_stage_marker)"
      set +e
      ( cd "$server" && bk_nice rsync -a --chmod=Dgo-w,Fgo-w --delete --delete-excluded --numeric-ids "${follow[@]}" "${verify[@]}" "${ex[@]}" -- ./ "$root/" )
      rc=$?
      set -e
      if (( rc == 24 )); then
        bk_log WARN "rsync: some files vanished while copying (a live server does that); continuing"
        rc=0
      fi
      if (( rc != 0 )); then
        bk_log ERROR "rsync failed (exit $rc); the mirror is marked incomplete and healed by the next run"
        return 1
      fi
      rm -f -- "$(bk_stage_marker)"
      ;;
    reflink|fresh)
      root="$(bk_stage_dir)/snap"
      rm -rf -- "$root"
      mkdir -p "$root" || return 1
      BK_STAGE_SNAP="$root"
      if [[ "$mode" == reflink ]]; then
        local item
        ( cd "$server" && shopt -s nullglob dotglob && for item in *; do
            [[ "$item" == backups || "$item" == .mc-meta ]] && continue
            if [[ -L "$item" && "${BACKUP_FOLLOW_SYMLINKS:-true}" == true ]]; then
              cp -aL --reflink=auto -- "./$item" "$root/" || exit 1
            else
              cp -a --reflink=always -- "./$item" "$root/" || exit 1
            fi
          done ) || { bk_log ERROR "reflink snapshot failed"; return 1; }
        # cp cannot exclude, so the exclude list is applied by tar instead.
        BK_TAR_EXCLUDES=("${BK_EXCLUDES[@]}")
      else
        set +e
        ( cd "$server" && bk_nice rsync -a --chmod=Dgo-w,Fgo-w --numeric-ids "${follow[@]}" "${ex[@]}" -- ./ "$root/" )
        rc=$?
        set -e
        if (( rc == 24 )); then
          bk_log WARN "rsync: some files vanished while copying (a live server does that); continuing"
          rc=0
        fi
        (( rc == 0 )) || { bk_log ERROR "rsync failed (exit $rc)"; return 1; }
      fi
      ;;
    *) bk_log ERROR "Unknown staging mode: $mode"; return 1 ;;
  esac
  BK_STAGE_ROOT="$root"
}

# bk_stage_check_mirror <root>: refuses a mirror whose refresh never finished.
bk_stage_check_mirror() {
  if [[ -e "$(bk_stage_marker)" ]]; then
    bk_log ERROR "The staging mirror is incomplete (a previous refresh was interrupted); not archiving it"
    return 1
  fi
  return 0
}

# bk_stage_metadata <dest> <instance_scripts_dir>
# Everything outside SERVER_PATH needed to rebuild the management side: the
# scripts tree (without node_modules and logs), the systemd units and the
# api-server config. Lands in <dest>/.mc-meta.
bk_stage_metadata() {
  local dest="$1" instance_scripts_dir="$2" meta base_dir target_dir_name svc_file api_config
  meta="$dest/.mc-meta"
  rm -rf -- "$meta"
  mkdir -p "$meta/scripts" "$meta/systemd" || return 1
  BK_STAGE_META="$dest"
  # The install root holds scripts/, instances/ and services/. It is not the
  # server dir's parent: in the instances/ layout that is <root>/instances.
  base_dir="$(dirname "$(dirname "$instance_scripts_dir")")"
  target_dir_name="$(basename "$base_dir")"

  rsync -a --exclude='node_modules/' --exclude='logs/' --exclude='*.log' \
    "$instance_scripts_dir/" "$meta/scripts/" || return 1
  bk_log INFO "  ✓ scripts/ ($(du -sh "$meta/scripts" 2>/dev/null | cut -f1))"

  # ${target_dir_name}-manager.service is deliberately absent: the bundled web
  # interface was retired, so a new backup should not carry a unit that restore
  # would then reinstall.
  for svc_file in \
    "/etc/systemd/system/${INSTANCE_NAME}.service" \
    "/etc/systemd/system/${target_dir_name}-api-server.service"; do
    if [[ -f "$svc_file" ]]; then
      cp "$svc_file" "$meta/systemd/$(basename "$svc_file")"
      bk_log INFO "  ✓ systemd/$(basename "$svc_file")"
    fi
  done

  api_config="$base_dir/services/api-server/api-server-config.json"
  [[ -f "$api_config" ]] || api_config="$base_dir/api-server/api-server-config.json"
  if [[ -f "$api_config" ]]; then
    cp "$api_config" "$meta/api-server-config.json"
    bk_log INFO "  ✓ api-server-config.json"
  else
    bk_log WARN "  api-server-config.json not found; skipping"
  fi
}

# bk_stage_discard_run: per-run staging only; the mirror persists.
bk_stage_discard_run() {
  [[ -n "$BK_STAGE_SNAP" && -d "$BK_STAGE_SNAP" ]] && rm -rf -- "$BK_STAGE_SNAP"
  [[ -n "$BK_STAGE_META" && -d "$BK_STAGE_META" ]] && rm -rf -- "$BK_STAGE_META"
  BK_STAGE_SNAP=""
  BK_STAGE_META=""
  return 0
}

# bk_stage_remove_legacy_tmp: the tmp_backup trees of the previous design.
bk_stage_remove_legacy_tmp() {
  local d
  for d in "$BACKUPS_PATH/hourly/tmp_backup" "$BACKUPS_PATH"/archives/*/tmp_backup; do
    [[ -d "$d" ]] && rm -rf -- "$d"
  done
  return 0
}
