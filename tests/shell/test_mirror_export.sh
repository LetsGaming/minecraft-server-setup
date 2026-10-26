#!/bin/bash
# Tests for src/mirror/bin/export.sh against a fake source instance. rsync is the
# real one (MC_TEST_REAL_TOOLS=1); screen, sudo and friends are the usual shims.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"
source "$HERE/lib/mirror_fixture.sh"

# A source instance "src" with a running server whose saves are confirmed at once.
mirror_setup() {
  make_fixture; trap cleanup_fixture EXIT
  if ! have_real_rsync; then skip "mirror export" "needs the real rsync (MC_TEST_REAL_TOOLS=1)"; return 1; fi
  mk_instance src source
  server_running
  export SCREEN_SHIM_SAVE_LOG="$T/src/server/logs/latest.log"
}

shim_calls() { grep -c -- "$1" "$SHIM_LOG" 2> /dev/null || true; }
manifest() { mirror_manifest_get "$1" "$(snapshot_dir src)/MANIFEST" 2> /dev/null; }
mirror_manifest_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"; }

test_an_export_publishes_a_snapshot_with_a_manifest() {
  mirror_setup || return 0
  run_job src "$EXPORT_SH"
  assert_rc 0 "$RC" "exported"
  local snap; snap="$(snapshot_dir src)"
  assert_exists "$snap/minecraft/overworld/region/r.0.0.mca" "region files are in the snapshot"
  assert_exists "$snap/minecraft/overworld/entities/r.0.0.mca" "and entities"
  assert_exists "$snap/minecraft/overworld/poi/r.0.0.mca" "and points of interest"
  assert_missing "$snap/minecraft/overworld/data" "the dimension's own data folder is never exported"
  assert_eq "2" "$(manifest format)" "the manifest format"
  assert_eq "26.3" "$(manifest mc_version)" "the version comes from the server log"
  assert_eq "424242" "$(manifest level_seed)" "the seed comes from server.properties"
  assert_eq "6" "$(manifest files)" "four region files, one entities, one poi"
  assert_eq "c2me-fabric-1.0.jar" "$(manifest worldgen_mods)" "worldgen mods are listed, others are not"
  assert_eq "$(cat "$snap/MANIFEST")" "$(cat "$T/src/mirror/export/LATEST")" "LATEST is the newest manifest"
  assert_missing "$T/src/mirror/export/.save-off-active" "the save-off marker is gone"
}

test_saving_is_turned_off_for_the_copy_and_back_on_afterwards() {
  mirror_setup || return 0
  run_job src "$EXPORT_SH"
  assert_logged "save-off" "auto-save is turned off"
  assert_logged "save-all flush" "the world is flushed"
  assert_logged "save-on" "and turned back on"
  local off on
  off="$(grep -n 'save-off' "$SHIM_LOG" | head -1 | cut -d: -f1)"
  on="$(grep -n 'save-on' "$SHIM_LOG" | tail -1 | cut -d: -f1)"
  assert_eq "yes" "$([[ "$off" -lt "$on" ]] && echo yes || echo no)" "in that order"
}

test_an_unchanged_file_is_hard_linked_between_snapshots() {
  mirror_setup || return 0
  run_job src "$EXPORT_SH"
  local first; first="$(snapshot_dir src)"
  sleep 1.2 2> /dev/null || true
  echo changed > "$T/src/server/world/dimensions/minecraft/overworld/region/r.1.0.mca"
  # the shim's sleep does not wait; give the second snapshot its own name
  mv "$first" "$T/src/mirror/export/snapshots/20200101T000000Z"
  run_job src "$EXPORT_SH"
  assert_rc 0 "$RC" "second export"
  local second; second="$(snapshot_dir src)"
  assert_eq "$(stat -c %i "$T/src/mirror/export/snapshots/20200101T000000Z/minecraft/overworld/region/r.0.0.mca")" "$(stat -c %i "$second/minecraft/overworld/region/r.0.0.mca")" "an unchanged file shares its inode with the previous snapshot"
  assert_eq "changed" "$(cat "$second/minecraft/overworld/region/r.1.0.mca")" "a changed file has the new content"
}

test_only_the_newest_snapshots_are_kept() {
  mirror_setup || return 0
  mkdir -p "$T/src/mirror/export/snapshots"
  local s
  for s in 20200101T000000Z 20200102T000000Z 20200103T000000Z; do
    mkdir -p "$T/src/mirror/export/snapshots/$s"
  done
  run_job src "$EXPORT_SH"
  assert_eq "2" "$(find "$T/src/mirror/export/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')" "two snapshots remain"
  assert_missing "$T/src/mirror/export/snapshots/20200101T000000Z" "the oldest was pruned"
}

test_an_unconfirmed_save_aborts_without_a_snapshot_and_turns_saving_back_on() {
  mirror_setup || return 0
  unset SCREEN_SHIM_SAVE_LOG
  export SAVE_TIMEOUT_SECONDS=2
  run_job src "$EXPORT_SH"
  assert_rc 1 "$RC" "the export fails"
  assert_contains "$OUT" "did not confirm the save" "and says why"
  assert_eq "" "$(snapshot_dir src)" "no snapshot was published"
  assert_logged "save-on" "saving is back on"
  assert_missing "$T/src/mirror/export/.save-off-active" "the marker is cleared"
}

test_a_window_left_open_by_a_dead_run_is_closed_by_the_next_one() {
  mirror_setup || return 0
  mkdir -p "$T/src/mirror/export"
  : > "$T/src/mirror/export/.save-off-active"
  run_job src "$EXPORT_SH"
  assert_rc 0 "$RC" "the export still succeeds"
  assert_contains "$OUT" "previous export died inside the save-off window" "the stale window is reported"
  assert_missing "$T/src/mirror/export/.save-off-active" "and closed"
}

test_ensure_save_on_repairs_only_a_real_stale_window() {
  mirror_setup || return 0
  mkdir -p "$T/src/mirror/export"
  run_job src "$EXPORT_SH" --ensure-save-on
  assert_rc 0 "$RC" "nothing to do without a marker"
  assert_eq "0" "$(shim_calls 'save-on')" "no save-on is sent"
  : > "$T/src/mirror/export/.save-off-active"
  run_job src "$EXPORT_SH" --ensure-save-on
  assert_rc 0 "$RC" "a stale window is repaired"
  assert_logged "save-on" "saving is switched back on"
  assert_missing "$T/src/mirror/export/.save-off-active" "the marker is removed"
  : > "$T/src/mirror/export/.save-off-active"
  rm -f "$SHIM_STATE/screen_running"
  : > "$SHIM_LOG"
  run_job src "$EXPORT_SH" --ensure-save-on
  assert_eq "0" "$(shim_calls 'save-on')" "a stopped server needs no save-on"
  assert_missing "$T/src/mirror/export/.save-off-active" "but the marker is cleared"
}

test_a_stopped_server_is_copied_without_a_save_window() {
  mirror_setup || return 0
  rm -f "$SHIM_STATE/screen_running"
  run_job src "$EXPORT_SH"
  assert_rc 0 "$RC" "exported"
  assert_eq "0" "$(shim_calls 'save-off')" "no save-off for a stopped server"
  assert_contains "$OUT" "server stopped" "the log says so"
}

test_the_version_comes_from_the_suites_record_before_the_server_log() {
  mirror_setup || return 0
  printf '{"gameVersion":"26.4","modLoader":"fabric"}' > "$T/src/scripts/common/downloaded_versions.json"
  run_job src "$EXPORT_SH"
  assert_eq "26.4" "$(manifest mc_version)" "downloaded_versions.json wins over the log (26.3)"
}

test_a_rolled_over_log_does_not_lose_the_version() {
  mirror_setup || return 0
  # Minecraft rolls latest.log at midnight: the start-up line is gone from it
  echo "[00:00:00] [Server thread/INFO]: System chat: Saved the game" > "$T/src/server/logs/latest.log"
  printf '{"gameVersion":"26.3"}' > "$T/src/scripts/common/downloaded_versions.json"
  run_job src "$EXPORT_SH"
  assert_eq "26.3" "$(manifest mc_version)" "the version is still known"
}

test_the_versions_folder_is_the_second_source_and_an_ambiguous_one_is_not_guessed() {
  mirror_setup || return 0
  echo "[00:00:00] [Server thread/INFO]: nothing useful" > "$T/src/server/logs/latest.log"
  mkdir -p "$T/src/server/versions/26.2"
  run_job src "$EXPORT_SH"
  assert_eq "26.2" "$(manifest mc_version)" "a single versions/ folder names the version"
  mkdir -p "$T/src/server/versions/26.1"
  run_job src "$EXPORT_SH"
  assert_eq "unknown" "$(manifest mc_version)" "two folders are not guessed between"
}

test_a_log_without_a_version_line_gives_unknown_not_a_silent_failure() {
  mirror_setup || return 0
  echo "[00:00:00] [Server thread/INFO]: nothing useful" > "$T/src/server/logs/latest.log"
  run_job src "$EXPORT_SH"
  assert_rc 0 "$RC" "the export still succeeds"
  assert_eq "unknown" "$(manifest mc_version)" "the version is recorded as unknown"
}

test_stage_mode_copies_the_backup_staging_mirror_without_a_save_window() {
  mirror_setup || return 0
  mirror_set "$T/src" MIRROR_SOURCE_MODE stage
  mkdir -p "$T/src/backups/.stage" "$T/src/backups/.meta"
  mirror_world "$T/src/backups/.stage/mirror" staged
  echo '{"finished":"now","rc":0}' > "$T/src/backups/.meta/last_backup.json"
  run_job src "$EXPORT_SH"
  assert_rc 0 "$RC" "exported from the staging mirror"
  assert_eq "staged-region-0" "$(cat "$(snapshot_dir src)/minecraft/overworld/region/r.0.0.mca")" "the staged content is what was exported"
  assert_eq "0" "$(shim_calls 'save-off')" "the export opened no save-off window of its own"
}

test_stage_mode_refuses_an_incomplete_or_stale_staging_copy() {
  mirror_setup || return 0
  mirror_set "$T/src" MIRROR_SOURCE_MODE stage
  mkdir -p "$T/src/backups/.stage" "$T/src/backups/.meta"
  mirror_world "$T/src/backups/.stage/mirror" staged
  echo '{}' > "$T/src/backups/.meta/last_backup.json"
  : > "$T/src/backups/.stage/MIRROR_INCOMPLETE"
  run_job src "$EXPORT_SH"
  assert_rc 69 "$RC" "an incomplete staging copy is refused"
  rm -f "$T/src/backups/.stage/MIRROR_INCOMPLETE"
  touch -d '3 hours ago' "$T/src/backups/.meta/last_backup.json"
  run_job src "$EXPORT_SH"
  assert_rc 69 "$RC" "a stale one too"
  assert_contains "$OUT" "older than" "and says so"
}

test_the_export_refuses_a_mirror_that_is_off_or_has_the_wrong_role() {
  mirror_setup || return 0
  mirror_set "$T/src" MIRROR_ROLE target
  run_job src "$EXPORT_SH"
  assert_rc 78 "$RC" "the wrong role is a config error"
  assert_contains "$OUT" "MIRROR_ROLE=source" "and names the needed role"
  mirror_set "$T/src" MIRROR_ROLE source
  mirror_set "$T/src" MIRROR_ENABLED false
  run_job src "$EXPORT_SH"
  assert_rc 78 "$RC" "a disabled mirror is refused"
}

test_the_export_refuses_bad_settings_and_a_missing_layout() {
  mirror_setup || return 0
  mirror_set "$T/src" MIRROR_KEEP_SNAPSHOTS 1
  run_job src "$EXPORT_SH"
  assert_rc 78 "$RC" "keeping fewer than 2 snapshots is refused"
  mirror_set "$T/src" MIRROR_KEEP_SNAPSHOTS 2
  mirror_set "$T/src" MIRROR_DIMS "minecraft/overworld ../etc"
  run_job src "$EXPORT_SH"
  assert_rc 78 "$RC" "only the three vanilla dimensions can be listed"
  mirror_set "$T/src" MIRROR_DIMS "minecraft/overworld"
  rm -rf "$T/src/server/world/dimensions"
  run_job src "$EXPORT_SH"
  assert_rc 69 "$RC" "a world without the 26.x layout is refused"
}

test_too_little_free_space_stops_before_anything_is_copied() {
  mirror_setup || return 0
  export DF_SHIM_AVAIL=1000
  run_job src "$EXPORT_SH"
  assert_rc 73 "$RC" "exit 73 for no space"
  assert_eq "" "$(snapshot_dir src)" "nothing was copied"
  assert_eq "0" "$(shim_calls 'save-off')" "and no save window was opened"
}

run_tests
