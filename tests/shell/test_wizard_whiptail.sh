#!/bin/bash
# Whiptail wrappers, driven by the scriptable whiptail shim (WHIPTAIL_SHIM_REPLIES).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin" "$T/state"
  cp "$HERE/shims/whiptail" "$T/bin/"
  chmod +x "$T/bin/whiptail"
  export SHIM_LOG="$T/shim.log" SHIM_STATE="$T/state"
  : > "$SHIM_LOG"
  export PATH="$T/bin:$PATH"
  export MC_SETUP_TERM_SIZE="30 100" TERM=xterm MC_SETUP_FORCE_TTY=1
}

# Runs one wrapper with the given canned replies; prints "<stdout>|rc=<n>".
wt() { # replies (newline separated), function, args...
  local replies="$1" out rc=0
  shift
  printf '%s\n' "$replies" > "$T/replies"
  rm -f "$T/state/whiptail.count"
  out="$(
    export WHIPTAIL_SHIM_REPLIES="$T/replies"
    source "$REPO/src/wizard/whiptail.sh"
    "$@" 2>/dev/null
  )" || rc=$?
  echo "$out|rc=$rc"
}

test_input_returns_text() {
  setup
  assert_eq "my-server|rc=0" "$(wt '0|my-server' wt_input "Name" "Pick a name" "server")" "answer printed"
  assert_logged "--inputbox" "inputbox widget used"
  assert_logged "--output-fd 3" "answer read from fd 3"
  assert_logged "whiptail --output-fd 3 --title Name --cancel-button Back --inputbox Pick a name 10 78 server" "exact inputbox call"
}

test_exit_1_maps_to_back() {
  setup
  assert_eq "|rc=10" "$(wt '1|' wt_input "Name" "Pick a name" "server")" "input back"
  assert_eq "|rc=10" "$(wt '1|' wt_menu "T" "Pick" a a "Alpha" b "Beta")" "menu back"
}

test_exit_255_maps_to_cancel() {
  setup
  assert_eq "|rc=11" "$(wt '255|' wt_input "Name" "Pick a name" "server")" "input cancel"
  assert_eq "|rc=11" "$(wt '255|' wt_yesno "T" "Sure?" yes)" "yesno cancel"
  assert_eq "|rc=11" "$(wt '2|' wt_password "T" "Secret")" "other failure is cancel"
}

test_password_prints_text() {
  setup
  assert_eq "s3cret|rc=0" "$(wt '0|s3cret' wt_password "T" "Secret")" "password answer"
  assert_eq "|rc=10" "$(wt '1|' wt_password "T" "Secret")" "password back"
}

test_yesno_prints_yes_or_no() {
  setup
  assert_eq "yes|rc=0" "$(wt '0|' wt_yesno "T" "Sure?" yes)" "yes"
  assert_eq "no|rc=0" "$(wt '1|' wt_yesno "T" "Sure?" yes)" "no is not back"
  : > "$SHIM_LOG"
  wt '0|' wt_yesno "T" "Sure?" no > /dev/null
  assert_logged "--defaultno" "default no honoured"
}

test_unavailable_when_term_dumb() {
  setup
  local rc=0
  (source "$REPO/src/wizard/whiptail.sh"; TERM=dumb wt_available) || rc=$?
  assert_rc 1 "$rc" "dumb terminal"
  rc=0
  (source "$REPO/src/wizard/whiptail.sh"; unset TERM; wt_available) || rc=$?
  assert_rc 1 "$rc" "TERM unset"
  rc=0
  (source "$REPO/src/wizard/whiptail.sh"; wt_available) || rc=$?
  assert_rc 0 "$rc" "usable terminal"
}

test_unavailable_when_terminal_too_small() {
  setup
  local rc=0
  (source "$REPO/src/wizard/whiptail.sh"; MC_SETUP_TERM_SIZE="30 69" wt_available) || rc=$?
  assert_rc 1 "$rc" "too narrow"
  rc=0
  (source "$REPO/src/wizard/whiptail.sh"; MC_SETUP_TERM_SIZE="19 100" wt_available) || rc=$?
  assert_rc 1 "$rc" "too short"
  rc=0
  (source "$REPO/src/wizard/whiptail.sh"; MC_SETUP_TERM_SIZE="20 70" wt_available) || rc=$?
  assert_rc 0 "$rc" "exact minimum"
}

test_unavailable_when_whiptail_missing() {
  setup
  local rc=0
  rm -f "$T/bin/whiptail"
  (source "$REPO/src/wizard/whiptail.sh"; PATH="$T/bin:/nonexistent" wt_available) || rc=$?
  assert_rc 1 "$rc" "no whiptail on PATH"
}

test_checklist_returns_tags() {
  setup
  local out
  out="$(wt '0|mods\nbackups' wt_checklist "Extras" "Pick" "mods" mods "Mods" backups "Backups" api "API")"
  assert_eq $'mods\nbackups|rc=0' "$out" "one tag per line"
  assert_logged "--checklist" "checklist widget used"
  assert_logged "--separate-output" "separate output requested"
  assert_logged "mods Mods on backups Backups off api API off" "defaults pre-checked"
}

test_empty_checklist_prints_nothing() {
  setup
  assert_eq "|rc=0" "$(wt '0|' wt_checklist "Extras" "Pick" "" mods "Mods" api "API")" "no phantom empty tag"
  printf '0|
' > "$T/replies"
  rm -f "$T/state/whiptail.count"
  (
    export WHIPTAIL_SHIM_REPLIES="$T/replies"
    source "$REPO/src/wizard/whiptail.sh"
    wt_checklist "Extras" "Pick" "" mods "Mods" 2>/dev/null > "$T/raw"
  )
  assert_eq "0" "$(wc -c < "$T/raw" | tr -d ' ')" "no bytes written"
}

test_unavailable_without_known_size() {
  setup
  local rc=0
  (source "$REPO/src/wizard/whiptail.sh"; unset MC_SETUP_TERM_SIZE; stty() { return 1; }; wt_available) || rc=$?
  assert_rc 1 "$rc" "no size available"
  rc=0
  (source "$REPO/src/wizard/whiptail.sh"; MC_SETUP_TERM_SIZE=garbage wt_available) || rc=$?
  assert_rc 1 "$rc" "unparsable size"
}

test_unavailable_when_stderr_not_a_tty() {
  setup
  local rc=0
  (source "$REPO/src/wizard/whiptail.sh"; unset MC_SETUP_FORCE_TTY; wt_available 2>/dev/null) 2>/dev/null || rc=$?
  assert_rc 1 "$rc" "stderr is not a tty"
}

test_available_with_forced_tty_and_good_size() {
  setup
  local rc=0
  (source "$REPO/src/wizard/whiptail.sh"; MC_SETUP_FORCE_TTY=1 MC_SETUP_TERM_SIZE="40 120" wt_available) || rc=$?
  assert_rc 0 "$rc" "forced tty, good size"
}

test_menu_and_radiolist_pass_items() {
  setup
  assert_eq "b|rc=0" "$(wt '0|b' wt_menu "T" "Pick" b a "Alpha" b "Beta")" "menu answer"
  assert_logged "--default-item b" "menu default"
  assert_eq "a|rc=0" "$(wt '0|a' wt_radiolist "T" "Pick" a a "Alpha" b "Beta")" "radiolist answer"
  assert_logged "a Alpha on b Beta off" "radiolist default on"
}

test_windows_sized_from_terminal() {
  setup
  local out
  MC_SETUP_TERM_SIZE="24 80" wt '0|x' wt_input "T" "Short" "" > /dev/null
  assert_logged "--inputbox Short 10 74" "width capped from 80 columns"
  : > "$SHIM_LOG"
  MC_SETUP_TERM_SIZE="garbage" wt '0|x' wt_input "T" "Short" "" > /dev/null
  assert_logged "--inputbox Short 10 74" "falls back to 24x80"
}

test_width_clamped_between_60_and_78() {
  setup
  : > "$SHIM_LOG"
  MC_SETUP_TERM_SIZE="30 200" wt '0|x' wt_input "T" "Short" "" > /dev/null
  assert_logged "--inputbox Short 10 78" "wide terminal capped at 78"
  : > "$SHIM_LOG"
  MC_SETUP_TERM_SIZE="30 40" wt '0|x' wt_input "T" "Short" "" > /dev/null
  assert_logged "--inputbox Short 10 60" "narrow terminal floored at 60"
}

test_height_capped_by_terminal() {
  setup
  local text
  text="$(printf 'line
%.0s' $(seq 1 40))"
  : > "$SHIM_LOG"
  MC_SETUP_TERM_SIZE="30 100" wt '0|x' wt_input "T" "$text" "" > /dev/null
  assert_logged " 28 78 " "height capped at rows-2"
}

test_shim_does_not_log_in_pass_through() {
  setup
  mkdir -p "$T/real"
  printf '#!/bin/bash
true
' > "$T/real/whiptail"
  chmod +x "$T/real/whiptail"
  (unset WHIPTAIL_SHIM_REPLIES; PATH="$T/bin:$T/real:$PATH" whiptail --version)
  assert_not_logged "whiptail" "no log without canned replies"
}

test_msgbox_ok_and_cancel() {
  setup
  assert_eq "|rc=0" "$(wt '0|' wt_msgbox "T" "Hello")" "ok"
  assert_eq "|rc=11" "$(wt '255|' wt_msgbox "T" "Hello")" "esc"
}

test_shim_passes_through_without_control_var() {
  setup
  local rc=0
  mkdir -p "$T/real"
  printf '#!/bin/bash\necho real-whiptail "$@"\n' > "$T/real/whiptail"
  chmod +x "$T/real/whiptail"
  out="$(unset WHIPTAIL_SHIM_REPLIES; PATH="$T/bin:$T/real:$PATH" whiptail --version)" || rc=$?
  assert_eq "real-whiptail --version" "$out" "real binary executed"
}

run_tests "$@"
