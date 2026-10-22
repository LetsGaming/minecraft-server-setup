#!/bin/bash
# Route selection. Stdin stands in for the keyboard; MC_SETUP_FORCE_TTY=1 makes it count as a terminal.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
}

# Prints "route=<ROUTE>" and "rc=<n>" after select_route with the given stdin.
route_result() { # stdin-text, then VAR=value assignments for the run
  local input="$1" out rc=0
  shift
  out="$(
    # shellcheck disable=SC2030
    export SCRIPT_DIR="$T"
    for assignment in "$@"; do export "${assignment?}"; done
    source "$REPO/src/common/ui.sh"
    source "$REPO/src/wizard/route.sh"
    printf '%s' "$input" | { select_route 2>&1; echo "route=$ROUTE"; }
  )" || rc=$?
  echo "$out"
  echo "rc=$rc"
}

test_existing_config_selects_power() {
  setup; echo '{}' > "$T/variables.json"
  assert_contains "$(route_result $'2\n' MC_SETUP_FORCE_TTY=1)" "route=power" "config wins over the prompt"
}

test_no_tty_no_flags_selects_power() {
  setup
  assert_contains "$(route_result "" MC_SETUP_FORCE_TTY=)" "route=power" "no terminal means power"
}

test_default_flag_forces_default() {
  setup; echo '{}' > "$T/variables.json"
  assert_contains "$(route_result "" DEFAULT_ROUTE=true EULA=true)" "route=default" "flag overrides the config"
}

test_default_flag_without_tty_requires_eula() {
  setup
  local out
  out="$(route_result "" DEFAULT_ROUTE=true EULA=false)"
  assert_contains "$out" "rc=1" "exits 1"
  assert_contains "$out" "--agree-eula" "message names the flag"
}

test_default_flag_with_tty_needs_no_eula() {
  setup
  assert_contains "$(route_result "" DEFAULT_ROUTE=true MC_SETUP_FORCE_TTY=1)" "route=default" "the wizard asks later"
}

test_guided_flag_forces_guided() {
  setup
  assert_contains "$(route_result "" GUIDED_ROUTE=true MC_SETUP_FORCE_TTY=1)" "route=guided" "flag forces guided"
}

test_guided_flag_without_tty_is_rejected() {
  setup
  local out
  out="$(route_result "" GUIDED_ROUTE=true)"
  assert_contains "$out" "rc=1" "exits 1"
  assert_contains "$out" "interactive terminal" "message explains"
}

test_both_flags_are_rejected() {
  setup
  assert_contains "$(route_result "" GUIDED_ROUTE=true DEFAULT_ROUTE=true MC_SETUP_FORCE_TTY=1)" "rc=1" "conflict"
}

test_prompt_preselects_default() {
  setup
  assert_contains "$(route_result $'\n' MC_SETUP_FORCE_TTY=1)" "route=default" "enter picks default"
}

test_prompt_choice_two_selects_guided() {
  setup
  local out
  out="$(route_result $'2\n' MC_SETUP_FORCE_TTY=1)"
  assert_contains "$out" "route=guided" "2 picks guided"
  assert_contains "$out" "1) Quick setup (recommended)  2) Guided setup" "choices are shown"
}

test_prompt_reasks_on_invalid_input() {
  setup
  assert_contains "$(route_result $'x\n2\n' MC_SETUP_FORCE_TTY=1)" "route=guided" "invalid input is asked again"
}

run_tests
