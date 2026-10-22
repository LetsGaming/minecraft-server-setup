#!/bin/bash
# xaero_config.sh apply/check on a temp server dir with empty fake jars, plus
# run_post_mod_config from src/common/setup.sh with the script replaced by a stub.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"
SCRIPT="$REPO/src/scripts/misc/xaero_config.sh"

LIB=config/xaero/lib/common.cfg
MINI=config/xaero/minimap/common.cfg
MAP=config/xaero/world-map/common.cfg

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  S="$T/server"
  mkdir -p "$S/mods"
}

both_jars() {
  : > "$S/mods/xaerominimap-fabric-26.3-26.6.1.jar"
  : > "$S/mods/xaeroworldmap-fabric-26.3-1.47.1.jar"
}

apply() { bash "$SCRIPT" apply "$S"; }
check() { bash "$SCRIPT" check "$S"; }

test_creates_files_with_only_key_line_when_absent() {
  setup; both_jars
  apply
  assert_file_content "$S/$LIB" "everyone_tracks_everyone = true" "lib file holds only its key"
  assert_file_content "$S/$MINI" "register_minimap_status_effects = false" "minimap file holds only its key"
  assert_file_content "$S/$MAP" "register_status_effects = false" "world map file holds only its key"
}

test_patches_value_in_place_keeps_other_lines() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf '# header\nallow_internet_access = true\neveryone_tracks_everyone=false\n\nother = 1\n' > "$S/$LIB"
  apply
  assert_eq $'# header\nallow_internet_access = true\neveryone_tracks_everyone=true\n\nother = 1' "$(cat "$S/$LIB")" "only the value changed"
}

test_appends_key_when_missing() {
  setup; both_jars
  mkdir -p "$S/config/xaero/minimap"
  printf 'allow_internet_access = true\nregister_minimap_status_effects_x = true' > "$S/$MINI"
  apply
  assert_eq $'allow_internet_access = true\nregister_minimap_status_effects_x = true\nregister_minimap_status_effects = false' "$(cat "$S/$MINI")" "key appended, lookalike key untouched"
}

test_idempotent_second_apply_no_change() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf 'a = 1\neveryone_tracks_everyone = false\n' > "$S/$LIB"
  apply
  local before after
  before="$(cat "$S/$LIB" "$S/$MINI" "$S/$MAP" | md5sum)"
  apply
  after="$(cat "$S/$LIB" "$S/$MINI" "$S/$MAP" | md5sum)"
  assert_eq "$before" "$after" "second apply changes nothing"
  assert_eq "common.cfg" "$(ls -A "$S/config/xaero/lib")" "no temp files left behind"
}

test_crlf_file_stays_crlf() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib" "$S/config/xaero/minimap"
  printf 'a = 1\r\neveryone_tracks_everyone = false\r\nb = 2\r\n' > "$S/$LIB"
  printf 'a = 1\r\n' > "$S/$MINI"
  apply
  assert_eq "$(printf 'a = 1\r\neveryone_tracks_everyone = true\r\nb = 2\r\n' | md5sum)" "$(md5sum < "$S/$LIB")" "replaced line keeps CRLF"
  assert_eq "$(printf 'a = 1\r\nregister_minimap_status_effects = false\r\n' | md5sum)" "$(md5sum < "$S/$MINI")" "appended line uses CRLF"
}

test_no_xaero_jar_creates_nothing() {
  setup
  : > "$S/mods/other-mod.jar"
  apply
  assert_missing "$S/config" "no config dir created"
  local out rc
  out="$(check)"; rc=$?
  assert_rc 0 "$rc" "check exits 0 without Xaero"
  assert_eq "SKIP $LIB"$'\n'"SKIP $MINI"$'\n'"SKIP $MAP" "$out" "check prints SKIP lines"
}

test_lib_key_when_only_one_mod_present() {
  setup
  : > "$S/mods/XaeroWorldMap-fabric-26.3-1.47.1.jar"
  apply
  assert_exists "$S/$LIB" "lib key applies for the world map alone"
  assert_exists "$S/$MAP" "world map key applies"
  assert_missing "$S/$MINI" "minimap key does not apply"
  rm -rf "$S/config" "$S/mods"/*
  : > "$S/mods/xaerominimap-fabric-26.3-26.6.1.jar"
  apply
  assert_exists "$S/$LIB" "lib key applies for the minimap alone"
  assert_exists "$S/$MINI" "minimap key applies"
  assert_missing "$S/$MAP" "world map key does not apply"
}

test_disabled_jars_are_ignored() {
  setup
  mkdir -p "$S/mods/disabled"
  : > "$S/mods/disabled/xaerominimap-fabric-26.3-26.6.1.jar"
  apply
  assert_missing "$S/config" "a jar under mods/disabled does not count"
}

test_both_naming_schemes_are_recognised() {
  local minimap world
  for minimap in xaerominimap-fabric-26.3-26.6.1.jar Xaeros_Minimap_25.2.10_Fabric_1.21.jar; do
    setup
    : > "$S/mods/$minimap"
    apply
    assert_exists "$S/$MINI" "$minimap: minimap file written"
    assert_exists "$S/$LIB" "$minimap: lib file written"
    assert_missing "$S/$MAP" "$minimap: does not count as the world map"
  done
  for world in xaeroworldmap-fabric-26.3-1.47.1.jar XaerosWorldMap_1.39.12_Fabric_1.21.jar; do
    setup
    : > "$S/mods/$world"
    apply
    assert_exists "$S/$MAP" "$world: world map file written"
    assert_exists "$S/$LIB" "$world: lib file written"
    assert_missing "$S/$MINI" "$world: does not count as the minimap"
  done
}

test_disabled_dir_is_ignored_for_old_names_too() {
  setup
  mkdir -p "$S/mods/disabled"
  : > "$S/mods/disabled/Xaeros_Minimap_25.2.10_Fabric_1.21.jar"
  : > "$S/mods/disabled/XaerosWorldMap_1.39.12_Fabric_1.21.jar"
  apply
  assert_missing "$S/config" "disabled old-name jars do not count"
}

test_check_reports_drift_and_exit_1() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib" "$S/config/xaero/minimap" "$S/config/xaero/world-map"
  printf 'everyone_tracks_everyone = false\r\n' > "$S/$LIB"
  printf 'x = 1\n' > "$S/$MINI"
  printf 'register_status_effects = false\n' > "$S/$MAP"
  local out rc
  out="$(check)"; rc=$?
  assert_rc 1 "$rc" "check exits 1 on drift or missing"
  assert_contains "$out" "DRIFT $LIB everyone_tracks_everyone (found false, want true)" "DRIFT line"
  assert_contains "$out" "MISSING $MINI register_minimap_status_effects" "MISSING line"
  assert_contains "$out" "OK $MAP register_status_effects" "OK line"
  apply
  out="$(check)"; rc=$?
  assert_rc 0 "$rc" "check exits 0 after apply"
}

test_file_mode_preserved() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf 'everyone_tracks_everyone = false\n' > "$S/$LIB"
  chmod 640 "$S/$LIB"
  if [[ "$(stat -c %a "$S/$LIB" 2> /dev/null)" != 640 ]]; then
    skip "test_file_mode_preserved" "this host cannot keep POSIX file modes"
    return
  fi
  apply
  assert_eq 640 "$(stat -c %a "$S/$LIB")" "mode kept after patching"
}

# run_post_mod_config with the real function and a stub xaero_config.sh.
post_mod() { # stub_exit_code  (jars via env XJAR=1)
  local sd="$T/repo" inst
  mkdir -p "$sd/src/scripts/misc"
  printf '#!/bin/bash\necho "stub $*" >> "%s/calls"\nexit %s\n' "$T" "$1" > "$sd/src/scripts/misc/xaero_config.sh"
  inst="$T/main/target/instances/inst"
  mkdir -p "$inst/mods"
  [[ -n "${XJAR:-}" ]] && : > "$inst/mods/$XJAR"
  (
    source "$REPO/src/common/logging.sh"
    source <(sed -n '/^run_post_mod_config()/,/^}/p' "$REPO/src/common/setup.sh")
    SCRIPT_DIR="$sd" MAIN_DIR="$T/main" TARGET_DIR_NAME=target INSTANCE_NAME=inst DRY_RUN=false
    run_post_mod_config
    echo "rc=$?"
  )
}

test_post_mod_config_runs_script_only_with_xaero_jar() {
  setup
  local out
  out="$(XJAR="" post_mod 0)"
  assert_missing "$T/calls" "no Xaero jar: script not called"
  assert_contains "$out" "rc=0" "no Xaero jar: returns 0"
  out="$(XJAR=XaeroMinimap-fabric-26.3-26.6.1.jar post_mod 0)"
  assert_contains "$(cat "$T/calls")" "stub apply $T/main/target/instances/inst" "Xaero jar: apply called with the instance dir"
  rm -f "$T/calls"
  out="$(XJAR=Xaeros_Minimap_25.2.10_Fabric_1.21.jar post_mod 0)"
  assert_contains "$(cat "$T/calls")" "stub apply" "old minimap name: apply called"
  rm -f "$T/calls"
  out="$(XJAR=XaerosWorldMap_1.39.12_Fabric_1.21.jar post_mod 0)"
  assert_contains "$(cat "$T/calls")" "stub apply" "old world map name: apply called"
}

test_post_mod_config_failure_only_warns() {
  setup
  local out
  out="$(XJAR=xaeroworldmap-fabric-26.3-1.47.1.jar post_mod 3)"
  assert_contains "$out" "[WARN]" "failure prints a warning"
  assert_contains "$out" "rc=0" "failure is not fatal"
}

test_empty_file_gets_the_key() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  : > "$S/$LIB"
  apply
  assert_file_content "$S/$LIB" "everyone_tracks_everyone = true" "key added to an empty file"
}

test_commented_key_is_not_the_key() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf '# everyone_tracks_everyone = false\n' > "$S/$LIB"
  apply
  assert_eq $'# everyone_tracks_everyone = false\neveryone_tracks_everyone = true' "$(cat "$S/$LIB")" "comment kept, real key appended"
}

test_key_name_prefix_cases() {
  setup; both_jars
  mkdir -p "$S/config/xaero/world-map" "$S/config/xaero/minimap"
  printf 'register_minimap_status_effects = false\n' > "$S/$MAP"
  printf 'register_minimap_status_effects = true\n' > "$S/$MINI"
  apply
  assert_eq $'register_minimap_status_effects = false\nregister_status_effects = false' "$(cat "$S/$MAP")" "world map file gets its own key"
  assert_eq "register_minimap_status_effects = false" "$(cat "$S/$MINI")" "minimap file only has its key patched"
}

test_last_line_without_newline_is_replaced() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf 'a = 1\neveryone_tracks_everyone = false' > "$S/$LIB"
  apply
  assert_eq "$(printf 'a = 1\neveryone_tracks_everyone = true' | md5sum)" "$(md5sum < "$S/$LIB")" "no newline added at the end"
}

test_mixed_line_endings_preserved() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf 'a = 1\r\neveryone_tracks_everyone = false\nb = 2\r\n' > "$S/$LIB"
  apply
  assert_eq "$(printf 'a = 1\r\neveryone_tracks_everyone = true\nb = 2\r\n' | md5sum)" "$(md5sum < "$S/$LIB")" "each line keeps its own ending"
}

test_server_dir_with_spaces() {
  setup
  S="$T/my server dir"
  mkdir -p "$S/mods"
  both_jars
  apply
  assert_file_content "$S/$MAP" "register_status_effects = false" "created under a path with spaces"
  assert_rc 0 "$(check > /dev/null; echo $?)" "check works there too"
}

test_trailing_text_after_value_kept_and_first_match_only() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib"
  printf 'everyone_tracks_everyone = false # note\neveryone_tracks_everyone = false\n' > "$S/$LIB"
  apply
  assert_eq $'everyone_tracks_everyone = true # note\neveryone_tracks_everyone = false' "$(cat "$S/$LIB")" "inline comment kept, duplicate left alone"
  assert_contains "$(check)" "OK $LIB everyone_tracks_everyone" "check reads the first match too"
}

test_failed_write_leaves_original_and_no_temp() {
  setup; both_jars
  mkdir -p "$S/config/xaero/lib" "$S/config/xaero/minimap"
  printf 'a = 1\neveryone_tracks_everyone = false\n' > "$S/$LIB"
  local before rc
  before="$(md5sum < "$S/$LIB")"
  (
    source "$SCRIPT"
    printf() { case "${FUNCNAME[1]:-}" in render | apply_key) return 1 ;; *) builtin printf "$@" ;; esac; }
    apply_key "$S/$LIB" everyone_tracks_everyone true
    echo "rc=$?" > "$T/rc"
    apply_key "$S/$MAP" register_status_effects false
    echo "rc=$?" >> "$T/rc"
  )
  assert_eq "$before" "$(md5sum < "$S/$LIB")" "original untouched after a failed write"
  assert_eq $'rc=1\nrc=1' "$(cat "$T/rc")" "both failures reported"
  assert_eq "common.cfg" "$(ls -A "$S/config/xaero/lib")" "no temp file beside the existing file"
  assert_missing "$S/$MAP" "no file created by a failed creation"
  assert_eq "" "$(ls -A "$S/config/xaero/world-map" 2> /dev/null)" "no temp file from the failed creation"
}

# run_post_mod_config edge cases: mods/ absent, dry run, caller's glob options.
test_post_mod_config_edge_cases() {
  setup
  local sd="$T/repo" out
  mkdir -p "$sd/src/scripts/misc"
  printf '#!/bin/bash\necho called >> "%s/calls"\n' "$T" > "$sd/src/scripts/misc/xaero_config.sh"
  mkdir -p "$T/main/target/instances/inst"
  out="$(
    source "$REPO/src/common/logging.sh"
    source <(sed -n '/^run_post_mod_config()/,/^}/p' "$REPO/src/common/setup.sh")
    SCRIPT_DIR="$sd" MAIN_DIR="$T/main" TARGET_DIR_NAME=target INSTANCE_NAME=inst DRY_RUN=false
    run_post_mod_config
    echo "rc=$?"
  )"
  assert_contains "$out" "rc=0" "mods/ absent is fine"
  assert_missing "$T/calls" "mods/ absent: nothing called"
  mkdir -p "$T/main/target/instances/inst/mods"
  : > "$T/main/target/instances/inst/mods/xaerominimap-x.jar"
  out="$(
    source "$REPO/src/common/logging.sh"
    source <(sed -n '/^run_post_mod_config()/,/^}/p' "$REPO/src/common/setup.sh")
    SCRIPT_DIR="$sd" MAIN_DIR="$T/main" TARGET_DIR_NAME=target INSTANCE_NAME=inst DRY_RUN=true
    run_post_mod_config
  )"
  assert_missing "$T/calls" "dry run calls nothing"
  assert_contains "$out" "[DRY-RUN]" "dry run only echoes"
  out="$(
    source "$REPO/src/common/logging.sh"
    source <(sed -n '/^run_post_mod_config()/,/^}/p' "$REPO/src/common/setup.sh")
    SCRIPT_DIR="$sd" MAIN_DIR="$T/main" TARGET_DIR_NAME=target INSTANCE_NAME=inst DRY_RUN=true
    run_post_mod_config > /dev/null
    shopt nullglob nocaseglob | tr -s ' \t' ' ' | tr '\n' ';'
  )"
  assert_eq "nullglob off;nocaseglob off;" "$out" "caller's glob options restored"
}

run_tests
