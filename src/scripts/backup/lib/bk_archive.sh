#!/bin/bash
# Building, verifying and publishing one archive. Needs bk_common.sh and
# BACKUPS_PATH. Archives are written as <tier>/.minecraft_backup_<stamp>.tar.zst.part
# (a leading dot keeps them out of every minecraft_backup_* listing) and renamed
# into place only after they verified. The checksum sidecar lives apart from
# the archives, in .meta/<tier>/<name>.sha256, so no listing ever sees it.

if [[ -n "${_BK_ARCHIVE_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_BK_ARCHIVE_LOADED=1

BK_TAR_EXCLUDES=()

# bk_archive_part_path <tier_dir> <stamp>
bk_archive_part_path() { echo "$1/.minecraft_backup_$2.tar.zst.part"; }

# bk_archive_sidecar_path <archive>: .meta/<tier path>/<name>.sha256
bk_archive_sidecar_path() {
  local file="$1" rel
  rel="${file#"$BACKUPS_PATH"/}"
  [[ "$rel" == "$file" ]] && rel="${file##*/}"
  echo "$BACKUPS_PATH/.meta/${rel}.sha256"
}

# bk_archive_remove_stale_parts: a .part is residue of a killed run; the lock
# held by the caller makes it safe to discard.
bk_archive_remove_stale_parts() {
  local dir
  for dir in "$BACKUPS_PATH/hourly" "$BACKUPS_PATH"/archives/*/; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 1 -name '.minecraft_backup_*.part' -type f -print -delete 2>/dev/null |
      while IFS= read -r f; do bk_log INFO "Removed stale partial archive: ${f#"$BACKUPS_PATH"/}"; done
  done
  return 0
}

# bk_archive_create <stage_root> <meta_root|""> <tier_dir> <stamp> <level> <hourly 0|1>
# Prints the .part path. Returns 1 when tar or zstd failed (the part is removed).
bk_archive_create() {
  local stage_root="$1" meta_root="$2" tier_dir="$3" stamp="$4" level="$5" hourly="$6"
  local part threads
  part="$(bk_archive_part_path "$tier_dir" "$stamp")"
  threads="$(bk_zstd_threads)"
  local tar_opts=(-cf -)
  [[ "$hourly" == 1 ]] && tar_opts+=(--exclude='*.jar')
  local pat
  for pat in "${BK_TAR_EXCLUDES[@]}"; do tar_opts+=(--exclude="$pat"); done
  tar_opts+=(-C "$stage_root" .)
  [[ -n "$meta_root" && -d "$meta_root/.mc-meta" ]] && tar_opts+=(-C "$meta_root" .mc-meta)

  rm -f -- "$part"
  local -a st
  local had_e=false
  [[ $- == *e* ]] && had_e=true
  set +e
  bk_nice tar "${tar_opts[@]}" 2>/dev/null | bk_nice zstd -q -f -T"$threads" -"$level" -o "$part" 2>/dev/null
  st=("${PIPESTATUS[@]}")
  $had_e && set -e
  if [[ "${st[0]}" -ne 0 || "${st[1]}" -ne 0 ]]; then
    bk_log ERROR "Compression failed (tar exit ${st[0]}, zstd exit ${st[1]}); removing partial archive"
    rm -f -- "$part"
    echo "$part"
    return 1
  fi
  echo "$part"
}

# bk_archive_verify <file>
# One decompression pass: zstd checks the frame checksums while tar lists the
# members, and the listing must show a world (a level.dat and a region file),
# else the archive holds something other than the server.
# Returns 1 on a stream failure, 65 when the content check failed.
bk_archive_verify() {
  local file="$1" listing rc=0
  case "$file" in
    *.tar.zst|*.tar.zst.part)
      listing="$( set -o pipefail; bk_nice zstd -dc "$file" 2>/dev/null | bk_nice tar -tf - 2>/dev/null )" || rc=$?
      ;;
    *.tar.gz|*.tar.gz.part)
      listing="$( set -o pipefail; bk_nice tar -tzf "$file" 2>/dev/null )" || rc=$?
      ;;
    *) rc=1 ;;
  esac
  if (( rc != 0 )); then
    bk_log ERROR "Validation failed: the archive does not decompress and list cleanly"
    return 1
  fi
  if ! grep -q -E '(^|/)level\.dat$' <<<"$listing"; then
    bk_log ERROR "Validation failed: no level.dat in the archive; nothing that looks like a world was backed up"
    return "$BK_EX_CONTENT"
  fi
  if ! grep -q -E '(^|/)region/[^/]+\.mca$' <<<"$listing"; then
    bk_log ERROR "Validation failed: no region/*.mca in the archive; the world would be empty"
    return "$BK_EX_CONTENT"
  fi
  BK_VERIFY_ENTRIES="$(grep -c . <<<"$listing" || true)"
  return 0
}

# bk_archive_write_sidecar <archive> [content]: tmp plus mv, so the sidecar is
# either whole or absent. Without content the sha256 of the archive is written.
bk_archive_write_sidecar() {
  local file="$1" content="${2:-}" side tmp
  side="$(bk_archive_sidecar_path "$file")"
  mkdir -p "$(dirname "$side")" || return 1
  tmp="$side.$$"
  if [[ -z "$content" ]]; then
    content="$(bk_nice sha256sum -- "$file" | cut -d' ' -f1)  ${file##*/}" || { rm -f -- "$tmp"; return 1; }
  fi
  printf '%s\n' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$side"
}

# bk_archive_publish <part> <final>: sidecar first, then the atomic rename.
bk_archive_publish() {
  local part="$1" final="$2"
  bk_archive_write_sidecar "$part" "$(bk_nice sha256sum -- "$part" | cut -d' ' -f1)  ${final##*/}" || return 1
  mv -f -- "$(bk_archive_sidecar_path "$part")" "$(bk_archive_sidecar_path "$final")" || return 1
  mv -T -- "$part" "$final"
}

# bk_archive_link_tiers <final> <tier...>: the same archive under every due
# tier directory, as a hardlink where possible (archives are immutable once
# published, so sharing the inode is safe; eviction counts link counts).
bk_archive_link_tiers() {
  local final="$1" name tier dest
  shift
  name="${final##*/}"
  for tier in "$@"; do
    [[ -n "$tier" ]] || continue
    dest="$BACKUPS_PATH/archives/$tier/$name"
    mkdir -p "$(dirname "$dest")"
    if ln -- "$final" "$dest" 2>/dev/null; then
      bk_log INFO "Linked into archives/$tier/ (hardlink)"
    elif cp --reflink=auto -p -- "$final" "$dest" 2>/dev/null || cp -p -- "$final" "$dest"; then
      bk_log INFO "Copied into archives/$tier/"
    else
      bk_log ERROR "Could not place the archive in archives/$tier/"
      return 1
    fi
    local side
    side="$(bk_archive_sidecar_path "$final")"
    if [[ -f "$side" ]]; then
      mkdir -p "$(dirname "$(bk_archive_sidecar_path "$dest")")"
      cp -- "$side" "$(bk_archive_sidecar_path "$dest")" 2>/dev/null || true
    fi
  done
}

# bk_archive_is_valid_quick <file>: 0 when the sidecar vouches for it (present,
# newer than the archive, archive non-empty), 1 when the archive is empty,
# 2 when nothing is known (no sidecar).
bk_archive_is_valid_quick() {
  local file="$1" side
  [[ -s "$file" ]] || return 1
  side="$(bk_archive_sidecar_path "$file")"
  [[ -f "$side" ]] || return 2
  [[ "$side" -nt "$file" || ! "$file" -nt "$side" ]] || return 2
  return 0
}
