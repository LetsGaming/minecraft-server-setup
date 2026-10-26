#!/bin/bash
# --mirror-target with --mirror-remote and --mirror-seed (src/common/args.sh value
# options, src/common/mirror_flags.sh): the Default route needs no hand-written
# variables.json for a creative mirror target.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

REAL_NODE="$(command -v node || true)"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  [[ -n "$REAL_NODE" ]]
}

# run <stdin-text> <env assignments...> -- <script>: runs the snippet in a clean subshell
parse() { # args...
  OUT="$(
    set +e
    source "$REPO/src/common/args.sh"
    declare -A ARG_OPTS=(["--mirror-target"]="MIRROR_TARGET=false|t" ["--y"]="ACCEPT_ALL=false|y")
    ARG_VALUE_OPTS=(["--mirror-remote"]="MIRROR_REMOTE|r" ["--mirror-seed"]="MIRROR_SEED|s")
    parse_args "$@"
    echo "T=$MIRROR_TARGET R=$MIRROR_REMOTE S=$MIRROR_SEED"
  )"
  RC=$?
}

check() { # route; env MIRROR_* from caller; stdin is the answers
  OUT="$(
    set +e
    exec 2>&1
    ROUTE="$1"
    source "$REPO/src/common/ui.sh"
    source "$REPO/src/common/mirror_flags.sh"
    mirror_flags_check
    echo "R=$MIRROR_REMOTE S=$MIRROR_SEED"
  )"
  RC=$?
}

test_value_options_accept_equals_and_space_forms() {
  setup || { skip "mirror flags" "node is not available"; return 0; }
  parse --mirror-target --mirror-remote=10.0.0.5 --mirror-seed -42
  assert_rc 0 "$RC" "parsed"
  assert_eq "T=true R=10.0.0.5 S=-42" "$OUT" "equals and space forms both work"
  parse --y
  assert_eq "T=false R= S=" "$OUT" "unset by default"
}

test_a_value_option_without_a_value_or_an_unknown_one_is_an_error() {
  setup || return 0
  parse --mirror-remote
  assert_rc 1 "$RC" "missing value"
  assert_contains "$OUT" "needs a value" "says so"
  parse --mirror-bogus=1
  assert_rc 1 "$RC" "unknown option with a value"
  assert_contains "$OUT" "Unknown option" "says so"
}

test_a_target_without_remote_and_seed_stops_without_a_terminal() {
  setup || return 0
  MIRROR_TARGET=true MIRROR_REMOTE="" MIRROR_SEED="" MIRROR_SOURCE=false check default < /dev/null
  assert_rc 1 "$RC" "refused"
  assert_contains "$OUT" "--mirror-remote=<host-or-ip> --mirror-seed=<level-seed>" "names the flags"
}

test_a_terminal_is_asked_for_the_missing_values() {
  setup || return 0
  MC_SETUP_FORCE_TTY=1 MIRROR_TARGET=true MIRROR_REMOTE="" MIRROR_SEED="" MIRROR_SOURCE=false check default <<< $'survival.lan\n123'
  assert_rc 0 "$RC" "accepted"
  assert_contains "$OUT" "R=survival.lan S=123" "answers are used"
}

test_given_values_are_validated() {
  setup || return 0
  MIRROR_TARGET=true MIRROR_REMOTE="a b" MIRROR_SEED=1 MIRROR_SOURCE=false check default < /dev/null
  assert_rc 1 "$RC" "bad host refused"
  MIRROR_TARGET=true MIRROR_REMOTE="h.lan" MIRROR_SEED='1;2' MIRROR_SOURCE=false check default < /dev/null
  assert_rc 1 "$RC" "bad seed refused"
  MIRROR_TARGET=true MIRROR_REMOTE="mcsync@h.lan" MIRROR_SEED='-9' MIRROR_SOURCE=false check default < /dev/null
  assert_rc 0 "$RC" "good values pass"
}

test_the_power_route_does_not_need_the_flags_and_other_misuse_is_refused() {
  setup || return 0
  MIRROR_TARGET=true MIRROR_REMOTE="" MIRROR_SEED="" MIRROR_SOURCE=false check power < /dev/null
  assert_rc 0 "$RC" "the file supplies them on the power route"
  MIRROR_TARGET=false MIRROR_REMOTE="h" MIRROR_SEED="" MIRROR_SOURCE=false check default < /dev/null
  assert_rc 1 "$RC" "a remote without --mirror-target"
  MIRROR_TARGET=false MIRROR_REMOTE="" MIRROR_SEED="" MIRROR_NO_PERMISSIONS=true MIRROR_SOURCE=false check default < /dev/null
  assert_rc 1 "$RC" "--mirror-no-permissions without --mirror-target"
  MIRROR_TARGET=true MIRROR_REMOTE="h" MIRROR_SEED="1" MIRROR_SOURCE=true check default < /dev/null
  assert_rc 1 "$RC" "source and target together"
}

apply() { # route, then env
  OUT="$(
    set +e
    exec 2>&1
    ROUTE="$1"; SCRIPT_DIR="$T/src"
    source "$REPO/src/common/mirror_flags.sh"
    mirror_flags_apply
  )"
  RC=$?
}

test_apply_writes_the_target_block_and_seed() {
  setup || return 0
  mkdir -p "$T/src/src/setup/management"
  cp "$REPO/src/setup/management/apply_mirror_flags.js" "$T/src/src/setup/management/"
  echo '{"JAVA":{"SERVER":{"SEED":""}}}' > "$T/src/variables.json"
  MIRROR_TARGET=true MIRROR_REMOTE=h.lan MIRROR_SEED=77 DRY_RUN=false apply default
  assert_rc 0 "$RC" "applied"
  assert_eq "mcsync@h.lan|77|true|target" "$(node -e 'const d=require(process.argv[1]);console.log([d.MIRROR.REMOTE,d.JAVA.SERVER.SEED,d.MIRROR.ENABLED,d.MIRROR.ROLE].join("|"))' "$(cd "$T/src" && pwd -W 2> /dev/null || pwd)/variables.json")" "file updated"
}

test_apply_leaves_a_power_route_file_alone_without_flags_and_honours_dry_run() {
  setup || return 0
  mkdir -p "$T/src/src/setup/management"
  cp "$REPO/src/setup/management/apply_mirror_flags.js" "$T/src/src/setup/management/"
  echo '{"X":1}' > "$T/src/variables.json"
  MIRROR_TARGET=true MIRROR_REMOTE="" MIRROR_SEED="" DRY_RUN=false apply power
  assert_eq '{"X":1}' "$(tr -d '\n' < "$T/src/variables.json")" "untouched on the power route"
  MIRROR_TARGET=true MIRROR_REMOTE=h MIRROR_SEED=1 DRY_RUN=true apply default
  assert_eq '{"X":1}' "$(tr -d '\n' < "$T/src/variables.json")" "untouched in a dry run"
  assert_contains "$OUT" "dry-run" "says what it would do"
}

run_tests
