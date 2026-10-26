#!/bin/bash
# run_mirror_setup in src/common/setup.sh: how a fresh install reaches the optional
# creative mirror. mirror.sh is replaced by a stub that records its arguments, so
# what is tested is the decision and the ordering, not the mirror itself.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

REAL_NODE="$(command -v node || true)"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  export SCRIPT_DIR="$T/src" MAIN_DIR="$T/home" TARGET_DIR_NAME=mc INSTANCE_NAME=creative DRY_RUN=false
  mkdir -p "$SCRIPT_DIR" "$T/bin"
  # node is the real one; the stub mirror.sh records what it is asked and can be told to fail
  ln -sf "$REAL_NODE" "$T/bin/node" 2> /dev/null || cp "$REAL_NODE" "$T/bin/node"
  cat > "$SCRIPT_DIR/mirror.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$MIRROR_STUB_LOG"
case "$1" in
  setup) [[ -z "${MIRROR_STUB_FAIL_SETUP:-}" ]] || exit 1 ;;
  prepare) [[ -z "${MIRROR_STUB_FAIL_PREPARE:-}" ]] || exit 1 ;;
esac
exit 0
SH
  export MIRROR_STUB_LOG="$T/stub.log"
  : > "$MIRROR_STUB_LOG"
  unset MIRROR_STUB_FAIL_SETUP MIRROR_STUB_FAIL_PREPARE MIRROR_SOURCE MIRROR_TARGET
  NO_START=false
  [[ -n "$REAL_NODE" ]]
}

config() { printf '%s' "$1" > "$SCRIPT_DIR/variables.json"; }

hook() { # runs the function in a subshell and reports NO_START afterwards
  OUT="$(
    log() { echo "LOG $*"; }
    warn() { echo "WARN $*"; }
    source "$REPO/src/common/logging.sh" 2> /dev/null || true
    source "$REPO/src/common/setup.sh"
    log() { echo "LOG $*"; }
    warn() { echo "WARN $*"; }
    run_mirror_setup
    echo "NO_START=$NO_START"
  )"
  RC=$?
}

logged() { cat "$MIRROR_STUB_LOG"; }

test_a_plain_install_does_nothing_about_the_mirror() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"INSTANCE_NAME":"creative","JAVA":{"SERVER":{}}}'
  hook
  assert_rc 0 "$RC" "no error"
  assert_eq "" "$(logged)" "mirror.sh is never called"
  assert_contains "$OUT" "NO_START=false" "and the server still starts"
  config '{"MIRROR":{"ENABLED":false,"ROLE":"target"},"JAVA":{"SERVER":{}}}'
  hook
  assert_eq "" "$(logged)" "a switched-off block is ignored too"
}

test_the_source_flag_sets_up_the_source_side() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"JAVA":{"SERVER":{}}}'
  MIRROR_SOURCE=true hook
  assert_eq "setup source --scripts-dir $T/home/mc/scripts/creative" "$(logged)" "the source side is requested for this instance"
  assert_contains "$OUT" "NO_START=false" "the server still starts"
}

test_the_config_block_alone_is_enough() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"MIRROR":{"ENABLED":true,"ROLE":"source"},"JAVA":{"SERVER":{}}}'
  hook
  assert_eq "setup source --scripts-dir $T/home/mc/scripts/creative" "$(logged)" "an enabled source block sets the source side up"
}

test_a_target_is_set_up_then_prepared_with_the_configured_seed() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"MIRROR":{"ENABLED":true,"ROLE":"target","REMOTE":"mcsync@survival.example"},"JAVA":{"SERVER":{"SEED":"-446251370538060616"}}}'
  hook
  assert_eq $'setup target --scripts-dir '"$T"$'/home/mc/scripts/creative --source survival.example --sync-mods --homes\nprepare --scripts-dir '"$T"$'/home/mc/scripts/creative --seed -446251370538060616' "$(logged)" "setup first, then prepare with the seed"
  assert_contains "$OUT" "NO_START=false" "a prepared target may start"
  assert_contains "$OUT" "docs/mirror.md" "the pairing is pointed out"
}

test_a_target_without_a_source_is_not_started() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"JAVA":{"SERVER":{}}}'
  MIRROR_TARGET=true hook
  assert_rc 0 "$RC" "the install itself is not failed"
  assert_eq "" "$(logged)" "nothing was run"
  assert_contains "$OUT" "MIRROR.REMOTE" "the missing setting is named"
  assert_contains "$OUT" "NO_START=true" "and the server is not started"
}

test_a_target_whose_setup_or_preparation_fails_is_not_started() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"MIRROR":{"ENABLED":true,"ROLE":"target","REMOTE":"mcsync@h"},"JAVA":{"SERVER":{"SEED":"1"}}}'
  MIRROR_STUB_FAIL_SETUP=1 hook
  assert_rc 0 "$RC" "the install itself is not failed"
  assert_contains "$OUT" "NO_START=true" "a failed setup blocks the start"
  assert_not_contains "$(logged)" "prepare" "and no preparation was attempted"
  : > "$MIRROR_STUB_LOG"
  MIRROR_STUB_FAIL_PREPARE=1 hook
  assert_contains "$OUT" "NO_START=true" "a failed preparation blocks the start"
  assert_contains "$OUT" "NOT started" "and says no world exists yet"
}

test_a_failing_source_setup_does_not_block_the_start() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"MIRROR":{"ENABLED":true,"ROLE":"source"},"JAVA":{"SERVER":{}}}'
  MIRROR_STUB_FAIL_SETUP=1 hook
  assert_rc 0 "$RC" "the install itself is not failed"
  assert_contains "$OUT" "NO_START=false" "a source is a normal server and still starts"
  assert_contains "$OUT" "mirror failed" "the failure is reported"
}

test_both_flags_together_are_refused_without_running_anything() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"JAVA":{"SERVER":{}}}'
  MIRROR_SOURCE=true MIRROR_TARGET=true hook
  assert_eq "" "$(logged)" "nothing was run"
  assert_contains "$OUT" "cannot be used together" "and the reason is given"
}

test_a_dry_run_prints_the_commands_and_runs_none() {
  setup || { skip "mirror hook" "node is not available"; return 0; }
  config '{"MIRROR":{"ENABLED":true,"ROLE":"source"},"JAVA":{"SERVER":{}}}'
  DRY_RUN=true hook
  assert_eq "" "$(logged)" "the stub was not called"
  assert_contains "$OUT" "[DRY-RUN]" "the command is shown"
}

run_tests
