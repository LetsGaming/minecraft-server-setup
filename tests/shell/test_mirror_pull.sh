#!/bin/bash
# Tests for src/mirror/bin/pull.sh: a source instance "src" really exports, the
# ssh shim makes its export folder the "remote", and the target instance "tgt"
# pulls and swaps. rsync is the real one (MC_TEST_REAL_TOOLS=1).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"
source "$HERE/lib/mirror_fixture.sh"

TW="$T/tgt/server/world/dimensions"

# Source exported once; target running with its own world, a plot dimension and
# the settings of a pull job.
pull_setup() {
  make_fixture; trap cleanup_fixture EXIT
  if ! have_real_rsync; then skip "mirror pull" "needs the real rsync (MC_TEST_REAL_TOOLS=1)"; return 1; fi
  mk_instance src source
  mk_instance tgt target
  TW="$T/tgt/server/world/dimensions"
  mkdir -p "$TW/fabricplots/plots/region"
  echo "plot-build" > "$TW/fabricplots/plots/region/r.0.0.mca"
  mkdir -p "$T/tgt/mirror/ssh"
  echo "key" > "$T/tgt/mirror/ssh/id_ed25519"
  echo "pinned" > "$T/tgt/mirror/ssh/known_hosts"
  mirror_set "$T/tgt" MIRROR_REMOTE "mcsync@source.test"
  mirror_set "$T/tgt" MIRROR_RETRIES 1
  mirror_set "$T/tgt" MIRROR_RETRY_DELAY 0
  server_running
  export SCREEN_SHIM_SAVE_LOG="$T/src/server/logs/latest.log"
  run_job src "$EXPORT_SH"
  [[ "$RC" == 0 ]] || { echo "setup export failed: $OUT"; return 1; }
  export SSH_SHIM_ROOT="$T/src/mirror/export"
  # the target's own log must carry the version the source reports
  echo "[00:00:00] [ServerMain/INFO]: Starting minecraft server version 26.3" > "$T/tgt/server/logs/latest.log"
  rm -f "$T/tgt/calls"
  unset SCREEN_SHIM_SAVE_LOG
}

# Rebuilds the source world and exports it again (the save must be confirmed).
reexport() { # label [regions]
  mirror_world "$T/src/server" "$1" "${2:-4}"
  SCREEN_SHIM_SAVE_LOG="$T/src/server/logs/latest.log" run_job src "$EXPORT_SH"
  [[ "$RC" == 0 ]] || echo "re-export failed: $OUT"
}

calls() { cat "$T/tgt/calls" 2> /dev/null | tr '\n' ' '; }
region() { cat "$TW/minecraft/overworld/region/$1" 2> /dev/null; }
plots_sum() { (cd "$TW/fabricplots" && find . -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1); }
outside_sum() { (cd "$T/tgt/server/world" && find . -type f ! -path './dimensions/minecraft/overworld/region/*' ! -path './dimensions/minecraft/overworld/entities/*' ! -path './dimensions/minecraft/overworld/poi/*' -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1); }

test_a_pull_swaps_the_mirrored_chunk_folders_and_nothing_else() {
  pull_setup || return 0
  local before_plots before_outside
  before_plots="$(plots_sum)"; before_outside="$(outside_sum)"
  run_job tgt "$PULL_SH"
  assert_rc 0 "$RC" "pulled and applied"
  assert_eq "src-region-0" "$(region r.0.0.mca)" "the region files are the source's"
  assert_eq "src-entities" "$(cat "$TW/minecraft/overworld/entities/r.0.0.mca")" "so are entities"
  assert_eq "src-poi" "$(cat "$TW/minecraft/overworld/poi/r.0.0.mca")" "and points of interest"
  assert_eq "$before_plots" "$(plots_sum)" "the plot dimension is untouched"
  assert_eq "tgt-border" "$(cat "$TW/minecraft/overworld/data/minecraft/world_border.dat")" "the dimension's own data folder is untouched"
  assert_eq "tgt" "$(cat "$T/tgt/server/world/level.dat")" "level.dat is untouched"
  assert_eq "$(mirror_manifest_get snapshot "$T/src/mirror/export/LATEST")" "$(cat "$T/tgt/mirror/sync/APPLIED")" "the applied snapshot is recorded"
  assert_eq "stop start " "$(calls)" "the server was stopped once and started once"
  assert_eq "tgt-region-0" "$(cat "$T/tgt/mirror/sync/rollback/minecraft/overworld/region/r.0.0.mca")" "the previous folders are kept for a rollback"
  assert_contains "$(cat "$T/tgt/server/world/dimensions/minecraft/overworld/region/r.0.0.mca")" "src" "(sanity) the live copy is the new one"
}

mirror_manifest_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"; }

test_pulling_the_same_snapshot_again_does_nothing_unless_forced() {
  pull_setup || return 0
  run_job tgt "$PULL_SH"
  rm -f "$T/tgt/calls"
  run_job tgt "$PULL_SH"
  assert_rc 0 "$RC" "second run succeeds"
  assert_contains "$OUT" "already applied" "and says so"
  assert_eq "" "$(calls)" "the server is not restarted"
  run_job tgt "$PULL_SH" --force
  assert_rc 0 "$RC" "--force re-applies"
  assert_eq "stop start " "$(calls)" "with a restart"
}

test_a_server_that_was_already_stopped_stays_stopped() {
  pull_setup || return 0
  rm -f "$SHIM_STATE/screen_running"
  run_job tgt "$PULL_SH"
  assert_rc 0 "$RC" "applied"
  assert_contains "$OUT" "left stopped" "the log says the server was left stopped"
  assert_eq "" "$(calls)" "no start or stop was issued"
  assert_eq "src-region-0" "$(region r.0.0.mca)" "the swap happened"
}

test_a_much_smaller_snapshot_is_refused_unless_forced() {
  pull_setup || return 0
  reexport tiny 1
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "the shrink guard refuses it"
  assert_contains "$OUT" "has 1 region files" "and gives the counts"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the mirror is untouched"
  assert_eq "" "$(calls)" "the server was never stopped"
  run_job tgt "$PULL_SH" --force
  assert_rc 0 "$RC" "--force accepts a real shrink"
  assert_eq "tiny-region-0" "$(region r.0.0.mca)" "and applies it"
}

test_a_snapshot_without_region_files_is_refused_even_when_forced() {
  pull_setup || return 0
  reexport empty 0
  run_job tgt "$PULL_SH" --force
  assert_rc 65 "$RC" "an empty snapshot is never applied"
  assert_contains "$OUT" "no region files" "and says why"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the mirror is untouched"
}

test_a_version_mismatch_is_refused_by_default_and_a_warning_when_allowed() {
  pull_setup || return 0
  echo "[00:00:00] [ServerMain/INFO]: Starting minecraft server version 26.2" > "$T/tgt/server/logs/latest.log"
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "different Minecraft versions are refused"
  assert_contains "$OUT" "version mismatch" "and named"
  mirror_set "$T/tgt" MIRROR_REQUIRE_SAME_VERSION false
  run_job tgt "$PULL_SH"
  assert_rc 0 "$RC" "allowed when configured"
  assert_contains "$OUT" "version mismatch" "but still reported"
}

test_a_differing_worldgen_mod_set_warns_and_can_refuse() {
  pull_setup || return 0
  rm -f "$T/tgt/server/mods/"*
  run_job tgt "$PULL_SH"
  assert_rc 0 "$RC" "a warning by default"
  assert_contains "$OUT" "worldgen mods differ" "names the mismatch"
  mirror_set "$T/tgt" MIRROR_PARITY refuse
  run_job tgt "$PULL_SH" --force
  assert_rc 65 "$RC" "refused when MIRROR_PARITY=refuse"
  mirror_set "$T/tgt" MIRROR_PARITY off
  run_job tgt "$PULL_SH" --force
  assert_rc 0 "$RC" "silent when off"
  assert_not_contains "$OUT" "worldgen mods differ" "nothing reported"
}

test_implausible_manifest_sizes_are_refused_before_any_arithmetic_wraps() {
  pull_setup || return 0
  sed -i "s/^bytes=.*/bytes=99999999999999999999/" "$T/src/mirror/export/LATEST"
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "a 20-digit size is refused"
  assert_contains "$OUT" "not plausible" "and called implausible"
  assert_eq "" "$(calls)" "the server was never stopped"
}

test_a_configured_snapshot_cap_refuses_a_bigger_snapshot() {
  pull_setup || return 0
  sed -i "s/^bytes=.*/bytes=3221225472/" "$T/src/mirror/export/LATEST"
  mirror_set "$T/tgt" MIRROR_MAX_SNAPSHOT_GB 2
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "3 GiB is over a 2 GiB cap"
  assert_contains "$OUT" "MIRROR_MAX_SNAPSHOT_GB" "and names the setting"
}

test_a_non_canonical_manifest_number_is_refused() {
  pull_setup || return 0
  sed -i "s/^created_epoch=\(.*\)/created_epoch=0\1/" "$T/src/mirror/export/LATEST"
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "a leading zero (octal in the shell) is refused"
  sed -i "s/^created_epoch=0/created_epoch=/; s/^files=\(.*\)/files=0\1/" "$T/src/mirror/export/LATEST"
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "so is one in the sizes"
  assert_eq "" "$(calls)" "the server was never stopped"
}

test_a_source_that_sends_more_than_it_declared_is_stopped_during_the_transfer() {
  pull_setup || return 0
  # a 6 MiB region file, a manifest that declares 1000 bytes, and a slow link
  mirror_world "$T/src/server" big 1
  head -c 6291456 /dev/zero > "$T/src/server/world/dimensions/minecraft/overworld/region/r.0.0.mca"
  SCREEN_SHIM_SAVE_LOG="$T/src/server/logs/latest.log" run_job src "$EXPORT_SH"
  sed -i "s/^bytes=.*/bytes=1000/" "$T/src/mirror/export/LATEST"
  mirror_set "$T/tgt" MIRROR_TRANSFER_SLACK_MB 0
  mirror_set "$T/tgt" MIRROR_BWLIMIT_KIB 2000
  run_job tgt "$PULL_SH"
  assert_rc 1 "$RC" "the pull fails"
  assert_contains "$OUT" "sending more than its manifest declared" "and says why"
  assert_eq "" "$(calls)" "the server was never stopped"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the mirror is untouched"
}

test_the_transfer_caps_the_size_of_a_single_file() {
  pull_setup || return 0
  run_job tgt "$PULL_SH"
  assert_logged "--max-size=2G" "rsync is told the largest region file it may fetch"
}

test_an_old_snapshot_is_refused() {
  pull_setup || return 0
  local f="$T/src/mirror/export/LATEST"
  sed -i "s/^created_epoch=.*/created_epoch=$(($(date +%s) - 100 * 3600))/" "$f"
  run_job tgt "$PULL_SH"
  assert_rc 65 "$RC" "a stale snapshot is refused"
  assert_contains "$OUT" "is the export timer running" "with a pointer to the cause"
}

test_too_little_space_changes_nothing_not_even_the_old_rollback() {
  pull_setup || return 0
  mkdir -p "$T/tgt/mirror/sync/rollback/minecraft/overworld/region"
  echo "old-rollback" > "$T/tgt/mirror/sync/rollback/minecraft/overworld/region/r.0.0.mca"
  export DF_SHIM_AVAIL=1000
  run_job tgt "$PULL_SH"
  assert_rc 73 "$RC" "exit 73"
  assert_eq "old-rollback" "$(cat "$T/tgt/mirror/sync/rollback/minecraft/overworld/region/r.0.0.mca")" "the previous rollback copy is intact"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the mirror is untouched"
  assert_eq "" "$(calls)" "the server was not stopped"
}

test_a_dry_run_checks_everything_and_changes_nothing() {
  pull_setup || return 0
  run_job tgt "$PULL_SH" --dry-run
  assert_rc 0 "$RC" "the dry run passes"
  assert_contains "$OUT" "dry run" "and says so"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the mirror is untouched"
  assert_eq "" "$(calls)" "the server was not stopped"
  assert_missing "$T/tgt/mirror/sync/APPLIED" "nothing is recorded"
}

test_an_unreachable_source_leaves_the_server_alone() {
  pull_setup || return 0
  export SSH_SHIM_FAIL=1
  run_job tgt "$PULL_SH"
  assert_rc 69 "$RC" "exit 69 for an unavailable source"
  assert_eq "" "$(calls)" "the server was not stopped"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the mirror is untouched"
}

test_a_transfer_that_drops_midway_leaves_an_incomplete_cache_and_the_server_running() {
  pull_setup || return 0
  export SSH_SHIM_FAIL_AFTER=1
  run_job tgt "$PULL_SH"
  assert_rc 1 "$RC" "the pull fails"
  assert_contains "$OUT" "the server was not touched" "and says the server was left alone"
  assert_exists "$T/tgt/mirror/sync/cache/.INCOMPLETE" "the cache is marked incomplete"
  assert_eq "" "$(calls)" "the server was never stopped"
  unset SSH_SHIM_FAIL_AFTER
  rm -f "$SHIM_STATE/ssh_calls"
  run_job tgt "$PULL_SH"
  assert_rc 0 "$RC" "the next run completes from the cache"
  assert_eq "src-region-0" "$(region r.0.0.mca)" "and applies the snapshot"
}

test_a_server_that_does_not_come_up_is_rolled_back() {
  pull_setup || return 0
  # the first start never reaches "Done"; the start after the rollback does
  cat > "$T/tgt/start.sh" <<SH
#!/bin/bash
n=\$(cat "$T/tgt/starts" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$T/tgt/starts"
echo start >> "$T/tgt/calls"
touch "$SHIM_STATE/screen_running"
[ "\$n" -ge 2 ] && echo "[00:00:09] [Server thread/INFO]: Done (3.210s)! For help, type \"help\"" >> "$T/tgt/server/logs/latest.log"
exit 0
SH
  mirror_set "$T/tgt" MIRROR_START_TIMEOUT 2
  run_job tgt "$PULL_SH"
  assert_rc 1 "$RC" "the run fails"
  assert_contains "$OUT" "rolled back" "and says it rolled back"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the previous region folder is back"
  assert_eq "tgt-entities" "$(cat "$TW/minecraft/overworld/entities/r.0.0.mca")" "and the previous entities"
  assert_exists "$T/tgt/mirror/sync/failed" "the rejected data is kept for a look"
  assert_missing "$T/tgt/mirror/sync/APPLIED" "the snapshot is not recorded as applied"
}

# A run killed between the folder moves must not leave new chunks next to old
# entities: every folder that has a rollback copy goes back.
test_recover_puts_back_a_half_applied_swap_consistently() {
  pull_setup || return 0
  local sync="$T/tgt/mirror/sync" w="$TW/minecraft/overworld"
  mkdir -p "$sync/rollback/minecraft/overworld"
  # region/ was swapped (new live, old in rollback); entities and poi never were
  mv "$w/region" "$sync/rollback/minecraft/overworld/region"
  mkdir -p "$w/region"; echo "src-region-0" > "$w/region/r.0.0.mca"
  : > "$sync/SWAP_IN_PROGRESS"
  run_job tgt "$PULL_SH" --recover
  assert_rc 0 "$RC" "recovery succeeds"
  assert_eq "tgt-region-0" "$(region r.0.0.mca)" "the old region folder is back"
  assert_eq "tgt-entities" "$(cat "$w/entities/r.0.0.mca")" "next to the old entities"
  assert_eq "src-region-0" "$(cat "$sync/failed/recover/minecraft/overworld/region/r.0.0.mca")" "the half-applied folder is kept for a look"
  assert_missing "$sync/SWAP_IN_PROGRESS" "the journal is cleared"
}

test_recover_restarts_a_server_the_sync_stopped() {
  pull_setup || return 0
  mkdir -p "$T/tgt/mirror/sync"
  : > "$T/tgt/mirror/sync/STOPPED_BY_SYNC"
  rm -f "$SHIM_STATE/screen_running"
  run_job tgt "$PULL_SH" --recover
  assert_rc 0 "$RC" "recovery succeeds"
  assert_eq "start " "$(calls)" "the server is started"
  assert_missing "$T/tgt/mirror/sync/STOPPED_BY_SYNC" "and the marker is cleared"
}

test_the_pull_refuses_a_mirror_that_is_off_or_a_target_without_a_world() {
  pull_setup || return 0
  rm -f "$T/tgt/server/world/level.dat"
  run_job tgt "$PULL_SH"
  assert_rc 78 "$RC" "no creative world yet is a config error"
  assert_contains "$OUT" "create the creative world first" "with the next step"
  mirror_set "$T/tgt" MIRROR_ENABLED false
  run_job tgt "$PULL_SH"
  assert_rc 78 "$RC" "a disabled mirror is refused"
}

run_tests
