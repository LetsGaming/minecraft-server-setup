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

run_tests
