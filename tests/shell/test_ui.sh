#!/bin/bash
# UI notices and the corrections collector. TTY state is forced with
# MC_SETUP_FORCE_TTY so no pty is needed.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"
source "$REPO/src/common/ui.sh"
source "$REPO/src/common/corrections.sh"

ESC=$'\033'

test_notice_has_prefix_without_color() {
  local out
  out="$(NO_COLOR=1 ui_notice adjusted "Port changed")"
  assert_contains "$out" "ADJUSTED:" "adjusted prefix present"
  assert_contains "$out" "Port changed" "message present"
  assert_not_contains "$out" "$ESC" "no escape codes"
}

test_notice_prefixes_per_severity() {
  local out
  out="$(NO_COLOR=1 ui_notice warning "w")"; assert_contains "$out" "WARNING:" "warning"
  out="$(NO_COLOR=1 ui_notice error "e")"; assert_contains "$out" "ERROR:" "error"
  out="$(NO_COLOR=1 ui_notice info "i")"; assert_contains "$out" "i" "info message"
}

test_notice_uses_color_on_tty() {
  local out
  out="$(unset NO_COLOR; MC_SETUP_FORCE_TTY=1 TERM=xterm ui_notice adjusted "Port changed")"
  assert_contains "$out" "${ESC}[" "colour escape present"
  assert_contains "$out" "ADJUSTED:" "prefix still present"
}

test_color_disabled_for_dumb_term_and_non_tty() {
  (unset NO_COLOR; MC_SETUP_FORCE_TTY=1 TERM=dumb ui_color_enabled); assert_rc 1 $? "dumb term"
  (unset NO_COLOR; MC_SETUP_FORCE_TTY=1 TERM=xterm NO_COLOR=1 ui_color_enabled); assert_rc 1 $? "NO_COLOR set"
  (unset NO_COLOR MC_SETUP_FORCE_TTY; TERM=xterm ui_color_enabled < /dev/null > /dev/null); assert_rc 1 $? "not a tty"
}

test_interactive_follows_force_tty() {
  (MC_SETUP_FORCE_TTY=1 ui_is_interactive); assert_rc 0 $? "forced tty"
  (unset MC_SETUP_FORCE_TTY; ui_is_interactive < /dev/null > /dev/null); assert_rc 1 $? "no tty"
}

test_corrections_collect_and_render() {
  corrections_reset
  correction_add adjusted "RAM" "8G" "4G" "host has little memory"
  correction_add warning "Port" "25565" "25566" "port in use"
  assert_eq "2" "$(corrections_count)" "two corrections"
  local out
  out="$(NO_COLOR=1 corrections_render)"
  assert_contains "$out" "RAM" "first subject"
  assert_contains "$out" "Port" "second subject"
  assert_contains "$out" "8G" "asked value"
  assert_contains "$out" "4G" "chosen value"
  assert_contains "$out" "ADJUSTED:" "adjusted prefix"
  assert_contains "$out" "WARNING:" "warning prefix"
  assert_not_contains "$out" "$ESC" "no colour"
}

test_corrections_reset() {
  corrections_reset
  correction_add adjusted "RAM" "8G" "4G" "why"
  corrections_reset
  assert_eq "0" "$(corrections_count)" "empty after reset"
  assert_eq "" "$(corrections_render)" "nothing rendered"
}

test_corrections_reject_bad_severity() {
  corrections_reset
  (correction_add bogus a b c d) > /dev/null 2>&1; assert_rc 1 $? "bad severity rejected"
  assert_eq "0" "$(corrections_count)" "nothing stored"
}

run_tests
