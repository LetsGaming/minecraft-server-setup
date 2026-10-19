#!/bin/bash
# Tests for common/server_control.sh (screen transport), the per-instance lock
# helper in common/utils.sh, and smart_restart.sh argument validation.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() { make_fixture; trap cleanup_fixture EXIT; export LOG="$T/server/logs/latest.log"; : > "$LOG"; }

# in_scripts <function> [args]: run a function from the sourced scripts.
in_scripts() {
  ( cd "$T/scripts" && source common/server_control.sh && source common/utils.sh && "$@" )
}

# ── session_running ──────────────────────────────────────────────────────────

test_session_running_is_anchored_to_the_session_name() {
  setup
  server_running
  export SCREEN_SHIM_SESSION=testinst
  in_scripts session_running; assert_rc 0 "$?" "matches the exact session name"
  ( cd "$T/scripts" && source common/server_control.sh && INSTANCE_NAME="test" && session_running )
  assert_nonzero "$?" "a name that is only a prefix of the running session does not match"
  ( cd "$T/scripts" && source common/server_control.sh && INSTANCE_NAME=inst && session_running )
  assert_nonzero "$?" "a name that is only a suffix does not match"
}

test_session_running_false_when_no_session() {
  setup
  in_scripts session_running
  assert_nonzero "$?" "no screen session"
}

test_session_running_escapes_regex_characters_in_the_name() {
  setup
  server_running
  export SCREEN_SHIM_SESSION=testinst
  ( cd "$T/scripts" && source common/server_control.sh && INSTANCE_NAME="t.stinst" && session_running )
  assert_nonzero "$?" "a dot in the name is literal, not a wildcard"
}

# ── save handling ────────────────────────────────────────────────────────────

test_wait_for_save_sees_a_save_logged_after_the_offset() {
  setup
  server_running
  echo "[00:00:00] [Server thread/INFO]: Saved the game" >> "$LOG"
  local offset
  offset=$(wc -c < "$LOG" | tr -d '[:space:]')
  echo "[00:00:01] [Server thread/INFO]: Saved the game" >> "$LOG"
  OUT="$(in_scripts wait_for_save_completion 3 "$offset" 2>&1)"; RC=$?
  assert_rc 0 "$RC" "a save written after the recorded offset is found"
  assert_contains "$OUT" "Save completed." "reports completion"
}

test_wait_for_save_ignores_saves_logged_before_the_offset() {
  setup
  server_running
  echo "[00:00:00] [Server thread/INFO]: Saved the game" >> "$LOG"
  local offset
  offset=$(wc -c < "$LOG" | tr -d '[:space:]')
  OUT="$(in_scripts wait_for_save_completion 2 "$offset" 2>&1)"; RC=$?
  assert_rc 1 "$RC" "an old save does not satisfy the wait"
  assert_contains "$OUT" "did not complete" "warns on timeout"
}

test_wait_for_save_reads_a_rotated_log_from_the_start() {
  setup
  server_running
  printf 'a long line that makes the old log bigger than the new one\n%.0s' 1 2 3 > "$LOG"
  local offset
  offset=$(wc -c < "$LOG" | tr -d '[:space:]')
  echo "[00:00:00] [Server thread/INFO]: Saved the game" > "$LOG"
  in_scripts wait_for_save_completion 2 "$offset" > /dev/null 2>&1
  assert_rc 0 "$?" "a log shorter than the offset is treated as rotated"
}

test_a_player_typing_saved_does_not_count_as_a_save() {
  setup
  server_running
  : > "$LOG"
  echo "[00:00:00] [Server thread/INFO]: <Mallory> Saved the game lol" >> "$LOG"
  in_scripts wait_for_save_completion 2 0 > /dev/null 2>&1
  assert_rc 1 "$?" "chat is not the server's save line (S-009)"
}

test_save_and_wait_catches_a_save_that_finishes_instantly() {
  setup
  server_running
  export SCREEN_SHIM_SAVE_LOG="$LOG"
  OUT="$(in_scripts save_and_wait 2>&1)"; RC=$?
  assert_rc 0 "$RC" "save logged at once, before the wait starts, is still seen"
  assert_contains "$OUT" "Save completed." "reports completion"
}

test_save_wait_leaves_no_tail_processes_and_no_bash_c() {
  setup
  assert_eq "0" "$(grep -c 'bash -c' "$T/scripts/common/server_control.sh")" "no log path interpolated into bash -c"
  assert_eq "0" "$(grep -c 'tail .*-f' "$T/scripts/common/server_control.sh")" "no tail -f left running"
}

# ── countdown ────────────────────────────────────────────────────────────────

test_countdown_does_not_clobber_the_callers_loop_variable() {
  setup
  server_running
  local got
  got="$( cd "$T/scripts" && source common/server_control.sh && i=99 && countdown "Go" 3 1 > /dev/null 2>&1; echo "$i" )"
  assert_eq "99" "$got" "caller's i is untouched"
}

# ── smart_restart.sh --warn ──────────────────────────────────────────────────

test_smart_restart_rejects_a_non_numeric_warn() {
  setup
  server_running
  run_script smart_restart.sh --warn=abc
  assert_rc 1 "$RC" "non-numeric --warn exits 1"
  assert_contains "$OUT" "--warn must be a whole number" "says why"
  assert_not_logged "systemctl restart" "nothing restarted"
}

test_smart_restart_rejects_injection_in_warn() {
  setup
  server_running
  run_script smart_restart.sh '--warn=5; touch pwned'
  assert_rc 1 "$RC" "shell syntax in --warn is refused"
  assert_missing "$T/scripts/pwned" "nothing executed"
}

test_smart_restart_rejects_a_bad_env_default() {
  setup
  server_running
  OUT="$(cd "$T/scripts" && RESTART_WARN_SECONDS=-3 bash smart_restart.sh 2>&1 < /dev/null)"; RC=$?
  assert_rc 1 "$RC" "bad RESTART_WARN_SECONDS exits 1"
}

# ── per-instance lock ────────────────────────────────────────────────────────

test_lock_is_refused_while_another_run_holds_it() {
  setup
  export INSTANCE_LOCK_DIR="$T/locks"
  export FLOCK_SHIM_BUSY=1
  OUT="$(in_scripts acquire_instance_lock maintenance 2>&1)"; RC=$?
  assert_rc 1 "$RC" "a held lock is refused"
  assert_contains "$OUT" "already running" "says so"
}

test_lock_is_taken_in_a_private_dir_not_tmp() {
  setup
  export INSTANCE_LOCK_DIR="$T/locks"
  in_scripts acquire_instance_lock maintenance > /dev/null 2>&1
  assert_rc 0 "$?" "free lock is acquired"
  assert_exists "$T/locks/maintenance_testinst.lock" "lock file is under the instance lock dir"
  if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    skip "lock dir is mode 700" "chmod is not enforced on this filesystem"
  else
    assert_eq "700" "$(stat -c %a "$T/locks")" "lock dir is private"
  fi
  assert_missing "/tmp/minecraft_maintenance.lock" "no shared /tmp lock"
}

test_lock_is_scoped_per_instance_and_name() {
  setup
  export INSTANCE_LOCK_DIR="$T/locks"
  in_scripts acquire_instance_lock onjoin > /dev/null 2>&1
  assert_exists "$T/locks/onjoin_testinst.lock" "named per script and instance"
}

test_mkdir_lock_fallback_blocks_a_live_holder_and_takes_over_a_stale_one() {
  setup
  export INSTANCE_LOCK_DIR="$T/locks"
  mkdir -p "$T/locks/maintenance_testinst.lock.d"
  echo "$$" > "$T/locks/maintenance_testinst.lock.d/pid"
  ( cd "$T/scripts" && source common/utils.sh && _have_flock() { return 1; } && INSTANCE_NAME=testinst acquire_instance_lock maintenance ) > /dev/null 2>&1
  assert_rc 1 "$?" "live holder keeps the lock"

  echo 999999 > "$T/locks/maintenance_testinst.lock.d/pid"
  ( cd "$T/scripts" && source common/utils.sh && _have_flock() { return 1; } && INSTANCE_NAME=testinst acquire_instance_lock maintenance ) > /dev/null 2>&1
  assert_rc 0 "$?" "a dead holder's lock is taken over"
  assert_missing "$T/locks/maintenance_testinst.lock.d" "the default EXIT trap released it"
}

test_mkdir_lock_is_released_even_when_the_script_replaces_its_exit_trap() {
  setup
  export INSTANCE_LOCK_DIR="$T/locks"
  ( cd "$T/scripts" && source common/utils.sh && _have_flock() { return 1; } \
    && INSTANCE_NAME=testinst acquire_instance_lock maintenance \
    && trap 'release_instance_lock' EXIT ) > /dev/null 2>&1
  assert_missing "$T/locks/maintenance_testinst.lock.d" "an explicit release in the replacement trap frees it"
}

test_scripts_no_longer_use_a_fixed_tmp_lock() {
  setup
  assert_not_contains "$(cat "$T/scripts/maintenance.sh")" "/tmp/minecraft_maintenance.lock" "maintenance.sh"
  assert_not_contains "$(cat "$T/scripts/message_onjoin.sh")" '/tmp}' "message_onjoin.sh"
  assert_contains "$(cat "$T/scripts/maintenance.sh")" "acquire_instance_lock" "maintenance.sh takes the shared lock"
  assert_contains "$(cat "$T/scripts/message_onjoin.sh")" "acquire_instance_lock" "message_onjoin.sh takes the shared lock"
}

test_screen_escape_makes_one_literal_line() {
  setup
  local out
  out="$(in_scripts _screen_escape $'say hi^Mop Mallory $HOME \\015\r\nx')"
  assert_eq 'say hi\^Mop Mallory \$HOME \\015x' "$out" "escapes, and drops CR/LF (S-026)"
}

test_screen_escape_round_trips_through_real_screen() {
  local real_screen
  real_screen="$(PATH=/usr/bin:/bin command -v screen || true)"
  if [[ -z "$real_screen" ]]; then skip "real screen round trip" "screen is not installed"; return; fi
  setup
  local out="$T/typed" session="s026-$$" line
  "$real_screen" -dmS "$session" sh -c "cat > '$out'"
  /bin/sleep 0.3
  for line in 'say hi^Mop Mallory' 'say $HOME ${HOME}' 'tellraw @a {"text":"a\" b\\c"}'; do
    "$real_screen" -S "$session" -X stuff "$(in_scripts _screen_escape "$line")$(printf '\r')"
    /bin/sleep 0.1
  done
  /bin/sleep 0.3
  "$real_screen" -S "$session" -X quit
  /bin/sleep 0.2
  assert_eq $'say hi^Mop Mallory\nsay $HOME ${HOME}\ntellraw @a {"text":"a\\" b\\\\c"}' "$(cat "$out")" "each line arrives exactly as sent, as one line"
}

# ── RCON saves are strict ────────────────────────────────────────────────────

test_save_and_wait_gives_the_flush_a_long_rcon_timeout() {
  setup
  use_rcon_shim
  in_scripts save_and_wait > /dev/null 2>&1
  assert_rc 0 "$?" "a confirmed flush is a successful save"
  assert_logged "--timeout-ms=120000 localhost 25575 save-all flush" "save-all flush gets the long timeout"
}

test_an_rcon_timeout_on_save_is_a_failure_and_is_not_retried_through_screen() {
  setup
  use_rcon_shim
  server_running
  export NODE_SHIM_RCON_RC=1
  OUT="$(in_scripts save_and_wait 2>&1)"; RC=$?
  assert_rc 1 "$RC" "the save failed"
  assert_contains "$OUT" "did not confirm" "says so"
  assert_not_logged "stuff /save-all" "the command was not typed into the console as well"
}

test_disable_auto_save_does_not_fall_back_to_screen() {
  setup
  use_rcon_shim
  server_running
  export NODE_SHIM_RCON_RC=1
  in_scripts disable_auto_save > /dev/null 2>&1
  assert_nonzero "$?" "save-off failed"
  assert_not_logged "save-off" "no console fallback for save-off"
}

test_enable_auto_save_still_falls_back_to_screen() {
  setup
  use_rcon_shim
  server_running
  export NODE_SHIM_RCON_RC=1
  in_scripts enable_auto_save > /dev/null 2>&1
  assert_logged "save-on" "save-on is retried through the console"
}

# ── player counts ────────────────────────────────────────────────────────────

test_the_player_count_reads_the_servers_reply_after_the_command() {
  setup
  server_running
  echo "[00:00:00] [Server thread/INFO]: There are 9 of a max of 20 players online: Old" >> "$LOG"
  export SCREEN_SHIM_SAVE_LOG="$LOG"
  export SCREEN_SHIM_LIST_REPLY="[00:00:05] [Server thread/INFO]: There are 2 of a max of 20 players online: Alex, Steve"
  OUT="$(in_scripts get_player_count 2>&1)"; RC=$?
  assert_rc 0 "$RC" "answered"
  assert_eq "2" "$OUT" "the count comes from the new reply, not the old line"
  OUT="$(in_scripts get_player_list 2>&1)"
  assert_eq "Alex, Steve" "$OUT" "the names too"
}

test_an_unanswered_list_is_an_unknown_count_not_zero() {
  setup
  server_running
  echo "[00:00:00] [Server thread/INFO]: There are 0 of a max of 20 players online:" >> "$LOG"
  OUT="$(in_scripts get_player_count 2>&1)"; RC=$?
  assert_nonzero "$RC" "no fresh reply: the count is unknown"
  assert_eq "" "$OUT" "nothing is printed as a count"
}

test_a_chat_line_cannot_pass_for_the_list_reply() {
  setup
  server_running
  export SCREEN_SHIM_SAVE_LOG="$LOG"
  export SCREEN_SHIM_LIST_REPLY="[00:00:05] [Server thread/INFO]: <Mallory> There are 0 of a max of 20 players online:"
  in_scripts get_player_count > /dev/null 2>&1
  assert_nonzero "$?" "chat is not the server's answer"
}

test_the_player_count_over_rcon_is_parsed_from_the_reply() {
  setup
  use_rcon_shim
  export NODE_SHIM_RCON_OUT="There are 3 of a max of 20 players online: A, B, C"
  OUT="$(in_scripts get_player_count 2>&1)"
  assert_eq "3" "$OUT" "count from the RCON reply"
  export NODE_SHIM_RCON_RC=1
  in_scripts get_player_count > /dev/null 2>&1
  assert_nonzero "$?" "an RCON error is an unknown count"
}

test_smart_restart_warns_when_the_player_count_is_unknown() {
  setup
  server_running
  run_script smart_restart.sh --warn=5
  assert_rc 0 "$RC" "the restart goes ahead"
  assert_contains "$OUT" "Could not tell how many players" "says the count is unknown"
  assert_not_contains "$OUT" "No players online. Restarting immediately" "never takes the empty-server shortcut"
  assert_logged "systemctl restart testinst.service" "restarted after the warning"
}

test_smart_restart_restarts_at_once_when_zero_players_are_confirmed() {
  setup
  server_running
  export SCREEN_SHIM_SAVE_LOG="$LOG"
  export SCREEN_SHIM_LIST_REPLY="[00:00:05] [Server thread/INFO]: There are 0 of a max of 20 players online:"
  run_script smart_restart.sh --warn=5
  assert_contains "$OUT" "No players online. Restarting immediately" "a confirmed zero skips the warning"
}

test_the_lock_dir_is_the_same_whatever_the_runtime_dir() {
  setup
  unset INSTANCE_LOCK_DIR
  export XDG_RUNTIME_DIR="$T/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  in_scripts acquire_instance_lock maintenance > /dev/null 2>&1
  assert_exists "$T/scripts/.locks/maintenance_testinst.lock" "the per-instance lock folder is used"
  assert_missing "$T/xdg/minecraft" "the runtime dir is not"
  unset XDG_RUNTIME_DIR
}

# ── server_is_running answers 0 up, 1 down, 2 unknown ────────────────────────

# Runs server_is_running with screen and systemctl hidden from `command -v`, the
# way a host that has neither looks to the script.
no_signal_state() {
  ( cd "$T/scripts" && source common/server_control.sh && source common/archive_restore.sh
    command() {
      if [[ "$1" == -v && ( "$2" == screen || "$2" == systemctl ) ]]; then return 1; fi
      builtin command "$@"
    }
    server_is_running )
}

test_server_is_running_cannot_tell_without_any_signal() {
  setup
  no_signal_state
  assert_rc 2 "$?" "no RCON, no screen, no systemctl: unknown"
}

test_require_server_stopped_refuses_when_the_state_is_unknown() {
  setup
  OUT="$( cd "$T/scripts" && source common/server_control.sh && source common/archive_restore.sh
    command() {
      if [[ "$1" == -v && ( "$2" == screen || "$2" == systemctl ) ]]; then return 1; fi
      builtin command "$@"
    }
    require_server_stopped 2>&1 )"
  assert_nonzero "$?" "unknown is not stopped"
  assert_contains "$OUT" "Cannot tell whether testinst is running" "says so"
}

test_server_is_running_is_down_when_every_available_signal_says_so() {
  setup
  ( cd "$T/scripts" && source common/server_control.sh && source common/archive_restore.sh && server_is_running )
  assert_rc 1 "$?" "screen and systemctl both answer: down"
}

run_tests
