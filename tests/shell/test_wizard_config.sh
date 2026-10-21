#!/bin/bash
# Wizard config writer. jq is wrapped so argv can be inspected and failures injected.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin" "$T/out"
  REAL_JQ="$(command -v jq)"
  export REAL_JQ
  cat > "$T/bin/jq" <<'SHIM'
#!/bin/bash
echo "jq $*" >> "$SHIM_LOG"
[ -z "${JQ_SHIM_FAIL:-}" ] || exit 1
[ -z "${JQ_SHIM_SLEEP:-}" ] || { echo "$$" > "$JQ_SHIM_SLEEP"; for ((i = 0; i < 600; i++)); do [ -e "$JQ_SHIM_SLEEP.release" ] && break; sleep 0.1; done; }
exec "$REAL_JQ" "$@"
SHIM
  chmod +x "$T/bin/jq"
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export PATH="$T/bin:$PATH"
  unset JQ_SHIM_FAIL
  export SCRIPT_DIR="$REPO"
}

# write <out> <key=value>...: runs config_write in a subshell with the given answers.
write() {
  local out="$1"
  shift
  (
    source "$REPO/src/wizard/manifest.sh"
    source "$REPO/src/wizard/config_writer.sh"
    declare -A ANSWERS=()
    set -u
    local kv
    for kv in "$@"; do ANSWERS["${kv%%=*}"]="${kv#*=}"; done
    config_write "$out"
  )
}

# cf_write <out> <pack> <key>: runs config_write_curseforge with the given answers.
cf_write() {
  (
    source "$REPO/src/wizard/manifest.sh"
    source "$REPO/src/wizard/config_writer.sh"
    declare -A ANSWERS=()
    [ -z "$2" ] || ANSWERS[curseforge_pack]="$2"
    [ -z "$3" ] || ANSWERS[curseforge_key]="$3"
    config_write_curseforge "$1"
  )
}

get() { jq -c "$2" "$1"; }

need_jq() { command -v jq > /dev/null 2>&1 || { skip "$1" "jq is missing"; return 1; }; }

test_unasked_keys_keep_example_defaults() {
  need_jq unasked_keys || return 0
  setup
  write "$T/out/v.json" INSTANCE_NAME=alpha
  assert_eq '"minecraft-server"' "$(get "$T/out/v.json" .TARGET_DIR_NAME)" "target dir kept"
  assert_eq '30' "$(get "$T/out/v.json" .BACKUPS.MAX_STORAGE_GB)" "storage default kept"
  assert_eq 'true' "$(get "$T/out/v.json" .JAVA.SERVER.FLIGHT_ENABLED)" "flight default kept"
  assert_eq '"512M"' "$(get "$T/out/v.json" .JAVA.JAVA_ARGS_CONFIG.metaspaceLimit)" "metaspace default kept"
}

test_answers_override_by_path() {
  need_jq answers_override || return 0
  setup
  write "$T/out/v.json" INSTANCE_NAME=alpha JAVA.SERVER.MOTD="Hi there" JAVA.SERVER.DIFFICULTY=hard JAVA.SERVER.VANILLA.VERSION=1.21.4 \
    server_kind=fabric memory=6G optional_mods=optional JAVA.SERVER.PORT=25566 \
    JAVA.SERVER.VANILLA.MODS.EXCLUDE="a, b" JAVA.JAVA_ARGS_CONFIG.g1gc.alwaysPreTouch=false
  local f="$T/out/v.json"
  assert_eq '"alpha"' "$(get "$f" .INSTANCE_NAME)" "instance name"
  assert_eq '"Hi there"' "$(get "$f" .JAVA.SERVER.MOTD)" "motd"
  assert_eq '"hard"' "$(get "$f" .JAVA.SERVER.DIFFICULTY)" "difficulty"
  assert_eq '"1.21.4"' "$(get "$f" .JAVA.SERVER.VANILLA.VERSION)" "version"
  assert_eq 'true' "$(get "$f" .JAVA.SERVER.VANILLA.USE_FABRIC)" "fabric"
  assert_eq '"6G"' "$(get "$f" .JAVA.JAVA_ARGS_CONFIG.minMemory)" "min memory"
  assert_eq '"6G"' "$(get "$f" .JAVA.JAVA_ARGS_CONFIG.maxMemory)" "max memory"
  assert_eq 'true' "$(get "$f" .JAVA.SERVER.VANILLA.MODS.OPTIONAL_MODS)" "optional mods"
  assert_eq '25566' "$(get "$f" .JAVA.SERVER.PORT)" "port is a number"
  assert_eq '["a","b"]' "$(get "$f" .JAVA.SERVER.VANILLA.MODS.EXCLUDE)" "exclude list"
  assert_eq 'false' "$(get "$f" .JAVA.JAVA_ARGS_CONFIG.g1gc.alwaysPreTouch)" "pretouch bool"
  write "$T/out/w.json" server_kind=vanilla
  assert_eq 'false' "$(get "$T/out/w.json" .JAVA.SERVER.VANILLA.USE_FABRIC)" "vanilla"
  write "$T/out/m.json" server_kind=modpack JAVA.SERVER.VANILLA.VERSION=1.21.4 curseforge_key=cfkey curseforge_pack=1
  assert_eq '"latest"' "$(get "$T/out/m.json" .JAVA.SERVER.VANILLA.VERSION)" "modpack ignores version"
  assert_not_contains "$(cat "$T/out/m.json")" 'cfkey' "curseforge key not in variables.json"
  write "$T/out/p.json" JAVA.SERVER.PORT=25565
  assert_eq '25565' "$(get "$T/out/p.json" .JAVA.SERVER.PORT)" "default port stays the example value"
  assert_eq '"number"' "$(get "$T/out/p.json" '.JAVA.SERVER.PORT|type')" "default port is a number"
}

test_empty_answers_yield_example_with_placeholders_blanked() {
  need_jq empty_answers || return 0
  setup
  write "$T/out/v.json"
  assert_eq "1" "$(grep -B1 -F '"${!ANSWERS[@]}"' "$REPO/src/wizard/config_writer.sh" | grep -cF '"${#ANSWERS[@]}" -gt 0')" "key loop sits behind the empty-array guard"
  local expected
  expected="$(jq -cS '.NOTIFICATIONS.WEBHOOK_URL = "" | .API_SERVER.API_KEY = "" | .SERVER_CONTROL.RCON_PASSWORD = ""' "$REPO/variables.example.json")"
  assert_eq "$expected" "$(jq -cS . "$T/out/v.json")" "example with blanked placeholders"
}

test_numbers_and_booleans_typed() {
  need_jq typed || return 0
  setup
  write "$T/out/v.json" JAVA.SERVER.MAX_PLAYERS=20 JAVA.SERVER.WHITELIST=true RESTART_SCHEDULE.ENABLED=false
  assert_eq '"number"' "$(get "$T/out/v.json" '.JAVA.SERVER.MAX_PLAYERS|type')" "max players number"
  assert_eq '20' "$(get "$T/out/v.json" .JAVA.SERVER.MAX_PLAYERS)" "max players value"
  assert_eq '"boolean"' "$(get "$T/out/v.json" '.JAVA.SERVER.WHITELIST|type')" "whitelist boolean"
  assert_eq 'true' "$(get "$T/out/v.json" .JAVA.SERVER.WHITELIST)" "whitelist value"
}

test_placeholders_blanked() {
  need_jq placeholders || return 0
  setup
  write "$T/out/v.json" INSTANCE_NAME=a
  assert_eq '""' "$(get "$T/out/v.json" .NOTIFICATIONS.WEBHOOK_URL)" "webhook blank"
  assert_eq '""' "$(get "$T/out/v.json" .API_SERVER.API_KEY)" "api key blank"
  assert_eq '""' "$(get "$T/out/v.json" .SERVER_CONTROL.RCON_PASSWORD)" "rcon password blank"
  write "$T/out/w.json" NOTIFICATIONS.WEBHOOK_URL=https://example.com/h
  assert_eq '"https://example.com/h"' "$(get "$T/out/w.json" .NOTIFICATIONS.WEBHOOK_URL)" "answered webhook kept"
}

test_generated_api_key_is_64_hex_and_not_in_process_args() {
  need_jq api_key || return 0
  setup
  write "$T/out/v.json" API_SERVER.ENABLED=true
  local key
  key="$(get "$T/out/v.json" .API_SERVER.API_KEY)"
  key="${key//\"/}"
  if [[ "$key" =~ ^[0-9a-f]{64}$ ]]; then _ok "key is 64 hex"; else _bad "key is 64 hex" "got ${#key} chars"; fi
  assert_not_logged "$key" "generated key absent from jq argv"
  write "$T/out/y.json" API_SERVER.ENABLED=true API_SERVER.API_KEY=0123456789abcdef0123456789abcdef0123456789abcdef
  assert_not_logged 0123456789abcdef0123456789abcdef "answered key absent from jq argv"
  assert_eq '"0123456789abcdef0123456789abcdef0123456789abcdef"' "$(get "$T/out/y.json" .API_SERVER.API_KEY)" "answered key kept"
}

test_api_key_generation_failure_fails_the_write() {
  need_jq key_failure || return 0
  setup
  printf '#!/bin/bash
exit 1
' > "$T/bin/od"
  chmod +x "$T/bin/od"
  local rc=0
  write "$T/out/v.json" API_SERVER.ENABLED=true 2> /dev/null || rc=$?
  assert_nonzero "$rc" "write fails"
  assert_missing "$T/out/v.json" "no output"
  assert_eq "" "$(ls -A "$T/out")" "no temp files left"
}

test_file_mode_is_600() {
  need_jq mode || return 0
  case "$(uname -s)" in MINGW* | MSYS*) skip "file mode is 600" "Windows filesystems do not keep POSIX modes"; return 0 ;; esac
  setup
  write "$T/out/v.json" INSTANCE_NAME=a
  assert_eq "600" "$(stat -c %a "$T/out/v.json")" "mode 600"
}

test_atomic_write_leaves_no_partial_file_on_failure() {
  need_jq atomic || return 0
  setup
  local rc=0
  JQ_SHIM_FAIL=1 write "$T/out/v.json" INSTANCE_NAME=a 2> /dev/null || rc=$?
  assert_nonzero "$rc" "failure reported"
  assert_missing "$T/out/v.json" "no output"
  assert_eq "" "$(ls -A "$T/out")" "no temp files left"
}

signals_unreliable() { # test-label
  case "$(uname -o 2> /dev/null)" in
    Msys | Cygwin)
      skip "$1" "signals are unreliable under MSYS/Cygwin; covered on Linux CI"
      return 0
      ;;
  esac
  return 1
}

# Background jobs of a non-interactive shell (or of a backgrounded test run) inherit an
# ignored SIGINT that bash cannot undo, so the job is started through a tiny exec wrapper
# that restores the default dispositions.
sig_exec() {
  if command -v perl > /dev/null 2>&1; then
    perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' -- "$@"
  else
    "$@"
  fi
}

# Polls for a marker file (up to ~60 s), signals the whole process group, waits for the
# process to end (up to ~60 s) and
# force-kills what is left. Sets SIGNAL_STATUS.
signal_when_started() { # signal pid marker
  local sig="$1" pid="$2" marker="$3" i
  for ((i = 0; i < 600; i++)); do
    [ -e "$marker" ] && break
    sleep 0.1
  done
  kill -s "$sig" -- "-$pid" 2> /dev/null
  for ((i = 0; i < 600; i++)); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2> /dev/null; then kill -9 -- "-$pid" "$pid" 2> /dev/null; fi
  SIGNAL_STATUS=0
  wait "$pid" 2> /dev/null || SIGNAL_STATUS=$?
}

# Starts config_write (or config_write_curseforge) in the background while a jq shim stalls
# it, sends the signal, and waits for the process to end.
interrupt_write() { # signal function out_path
  local sig="$1" fn="$2" out="$3" pid
  cat > "$T/write.sh" <<EOS
source "$REPO/src/wizard/manifest.sh"
source "$REPO/src/wizard/config_writer.sh"
declare -A ANSWERS=([INSTANCE_NAME]=a [curseforge_pack]=1 [curseforge_key]=k)
[ -z "\${WITH_EXIT_TRAP:-}" ] || trap 'echo ran > "$T/exit.marker"' EXIT
"$fn" "$out"
EOS
  set -m
  JQ_SHIM_SLEEP="$T/jq.started" sig_exec bash "$T/write.sh" < /dev/null > /dev/null 2>&1 &
  pid=$!
  set +m
  signal_when_started "$sig" "$pid" "$T/jq.started"
  return 0
}

test_interrupt_mid_write_removes_every_temp_file() {
  ! signals_unreliable interrupt_mid_write_removes_every_temp_file || return 0
  need_jq interrupt || return 0
  local sig fn
  for sig in INT TERM; do
    for fn in config_write config_write_curseforge; do
      (
        setup
        interrupt_write "$sig" "$fn" "$T/out/v.json"
        assert_exists "$T/jq.started" "$fn was stalled mid-write ($sig)"
        assert_missing "$T/out/v.json" "no output after $sig in $fn"
        assert_eq "" "$(ls -A "$T/out")" "no temp files after $sig in $fn"
      )
    done
  done
}

test_previous_traps_are_restored_after_a_write() {
  need_jq traps || return 0
  setup
  local out
  cat > "$T/traps.sh" <<EOS
source "$REPO/src/wizard/manifest.sh"
source "$REPO/src/wizard/config_writer.sh"
declare -A ANSWERS=([INSTANCE_NAME]=a)
trap 'echo mine' INT
config_write "$T/out/v.json" > /dev/null 2>&1
trap -p INT
trap -p TERM
EOS
  out="$(sig_exec bash "$T/traps.sh")"
  assert_eq "trap -- 'echo mine' SIGINT" "$out" "INT handler restored, TERM left unset"
}

test_signal_handler_removes_temp_files_without_delivering_a_signal() {
  setup
  echo secret > "$T/out/.variables.assign.x"
  echo '{}' > "$T/out/.variables.json.x"
  echo '{}' > "$T/out/keep.json"
  cat > "$T/handler.sh" <<EOS
source "$REPO/src/wizard/manifest.sh"
source "$REPO/src/wizard/config_writer.sh"
_CW_TMP="$T/out/.variables.json.x"
_CW_ASSIGN="$T/out/.variables.assign.x"
_cw_on_signal TERM
EOS
  sig_exec bash "$T/handler.sh" > /dev/null 2>&1
  assert_eq "keep.json" "$(ls -A "$T/out")" "only unrelated files are left"
}

test_route_handler_removes_only_files_this_run_created() {
  setup
  mkdir -p "$T/repo"
  echo old > "$T/repo/old.json"
  echo new > "$T/repo/new.json"
  echo cfg > "$T/repo/variables.json"
  cat > "$T/handler.sh" <<EOS
source "$REPO/src/wizard/manifest.sh"
source "$REPO/src/wizard/config_writer.sh"
source "$REPO/src/wizard/route.sh"
_WZ_CF_FILE="$T/repo/new.json"
_WZ_CFG_FILE="$T/repo/variables.json"
_wizard_on_write_signal TERM
EOS
  sig_exec bash "$T/handler.sh" > /dev/null 2>&1
  assert_missing "$T/repo/new.json" "the key file of this run is removed"
  assert_missing "$T/repo/variables.json" "the config of this run is removed"
  assert_exists "$T/repo/old.json" "other files are kept"
}

# Runs a script that installs a caller handler (one that returns, so a second run would show), the
# guard under test and then calls the handler directly; prints the output and rc=<n>.
chain_run() { # signal marker-file body
  local out rc=0
  cat > "$T/chain.sh" <<EOS
source "$REPO/src/wizard/manifest.sh"
source "$REPO/src/wizard/config_writer.sh"
source "$REPO/src/wizard/route.sh"
trap 'echo caller-ran; trap -p EXIT; rm -f "$2"' $1
trap 'echo exit-trap' EXIT
$3
echo not-reached
EOS
  out="$(bash "$T/chain.sh" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}

test_writer_handler_runs_the_callers_handler_once_before_exit() {
  setup
  local sig out status
  for sig in TERM INT; do
    status=143
    [ "$sig" = INT ] && status=130
    echo key > "$T/marker"
    echo secret > "$T/out/.variables.assign.x"
    echo '{}' > "$T/out/.variables.json.x"
    out="$(chain_run "$sig" "$T/marker" "_cw_guard_begin; _CW_TMP='$T/out/.variables.json.x'; _CW_ASSIGN='$T/out/.variables.assign.x'; _cw_on_signal $sig")"
    assert_eq 1 "$(grep -c '^caller-ran$' <<< "$out")" "the caller's handler ran exactly once ($sig)"
    assert_eq $'caller-ran\ntrap -- \'echo exit-trap\' EXIT\nexit-trap\nrc='"$status" "$out" "handler first, EXIT trap intact and run once, status $status ($sig)"
    assert_missing "$T/marker" "the caller's cleanup happened ($sig)"
    assert_eq "" "$(ls -A "$T/out")" "the writer's temp files are gone ($sig)"
  done
}

test_route_handler_runs_the_callers_handler_once_before_exit() {
  setup
  local sig out status
  mkdir -p "$T/repo"
  for sig in TERM INT; do
    status=143
    [ "$sig" = INT ] && status=130
    echo key > "$T/marker"
    echo '{}' > "$T/repo/cf.json"
    echo '{}' > "$T/repo/old.json"
    out="$(chain_run "$sig" "$T/marker" "_WZ_OLD_INT=\"\$(trap -p INT)\"; _WZ_OLD_TERM=\"\$(trap -p TERM)\"; _WZ_CF_FILE='$T/repo/cf.json'; _WZ_CFG_FILE='$T/repo/variables.json'; trap '_wizard_on_write_signal $sig' $sig; _wizard_on_write_signal $sig")"
    assert_eq 1 "$(grep -c '^caller-ran$' <<< "$out")" "the outer handler ran exactly once ($sig)"
    assert_eq $'caller-ran\ntrap -- \'echo exit-trap\' EXIT\nexit-trap\nrc='"$status" "$out" "handler first, EXIT trap intact and run once, status $status ($sig)"
    assert_missing "$T/marker" "the outer cleanup happened ($sig)"
    assert_missing "$T/repo/cf.json" "the key file of this run is removed ($sig)"
    assert_exists "$T/repo/old.json" "other files are kept ($sig)"
  done
}

test_exit_trap_is_kept_after_a_write() {
  need_jq exit-trap || return 0
  setup
  local out fn
  for fn in config_write config_write_curseforge; do
    out="$(
      source "$REPO/src/wizard/manifest.sh"
      source "$REPO/src/wizard/config_writer.sh"
      declare -A ANSWERS=([INSTANCE_NAME]=a [curseforge_pack]=1 [curseforge_key]=k)
      trap 'echo rollback' EXIT
      trap -p EXIT
      "$fn" "$T/out/$fn.json" > /dev/null 2>&1
      trap -p EXIT
      trap - EXIT
    )"
    assert_eq $'trap -- \'echo rollback\' EXIT\ntrap -- \'echo rollback\' EXIT' "$out" "EXIT trap kept across $fn"
  done
}

test_exit_trap_still_runs_after_an_interrupted_write() {
  ! signals_unreliable exit_trap_still_runs_after_an_interrupted_write || return 0
  need_jq exit-trap || return 0
  local sig fn
  for sig in INT TERM; do
    for fn in config_write config_write_curseforge; do
      (
        setup
        WITH_EXIT_TRAP=1 interrupt_write "$sig" "$fn" "$T/out/v.json"
        assert_exists "$T/exit.marker" "the caller's EXIT trap still ran after $sig in $fn"
        assert_eq "" "$(ls -A "$T/out")" "no temp files after $sig in $fn"
      )
    done
  done
}

test_refuses_to_overwrite() {
  need_jq overwrite || return 0
  setup
  echo keep > "$T/out/v.json"
  local rc=0
  write "$T/out/v.json" INSTANCE_NAME=a 2> /dev/null || rc=$?
  assert_nonzero "$rc" "overwrite refused"
  assert_eq "keep" "$(cat "$T/out/v.json")" "existing file intact"
}

test_seed_stays_string() {
  need_jq seed || return 0
  setup
  write "$T/out/v.json" JAVA.SERVER.SEED=12345
  assert_eq '"12345"' "$(get "$T/out/v.json" .JAVA.SERVER.SEED)" "seed string"
}

test_curseforge_file() {
  need_jq curseforge || return 0
  setup
  local rc=0
  cf_write "$T/out/cf.json" 123 'k$ey"x' || rc=$?
  assert_rc 0 "$rc" "written"
  assert_eq '{"pack_id":"123","api_key":"k$ey\"x"}' "$(get "$T/out/cf.json" .)" "content"
  assert_not_logged 'k$ey' "key absent from jq argv"
  rc=0
  cf_write "$T/out/cf.json" 1 "" 2> /dev/null || rc=$?
  assert_nonzero "$rc" "overwrite refused"
  rc=0
  cf_write "$T/out/none.json" "" "" || rc=$?
  assert_rc 0 "$rc" "no-op without answers"
  assert_missing "$T/out/none.json" "no file without answers"
}

test_output_passes_load_variables() {
  need_jq load_variables || return 0
  if ! command -v node > /dev/null 2>&1; then skip "output passes loadVariables.js" "node is missing"; return 0; fi
  setup
  mkdir -p "$T/src/setup/common"
  cp "$REPO/src/setup/common/loadVariables.js" "$T/src/setup/common/"
  write "$T/variables.json" INSTANCE_NAME=alpha API_SERVER.ENABLED=true server_kind=fabric memory=4G JAVA.SERVER.MAX_PLAYERS=12
  local loader="$T/src/setup/common/loadVariables.js" out rc=0
  command -v cygpath > /dev/null 2>&1 && loader="$(cygpath -m "$loader")"
  out="$(node -e 'try { require(process.argv[1])(); } catch (e) { console.log(e.message); process.exit(1); }' "$loader" 2>&1)" || rc=$?
  assert_rc 0 "$rc" "loader accepts the file ($out)"
}

run_tests
