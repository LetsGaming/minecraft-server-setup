#!/bin/bash
# Guided route end to end through run_wizard. whiptail, system facts and the Node resolver
# are shimmed; stdin stands in for the summary and EULA confirmations.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/repo/src/setup/download/json" "$T/bin" "$T/home" "$T/state"
  cp "$REPO/variables.example.json" "$T/repo/"
  cp "$HERE"/shims/{ss,ip,whiptail} "$T/bin/"
  printf '#!/bin/bash\n[ "$1" = -v ] && { echo v20.1.0; exit 0; }\nif [ -n "${NODE_SHIM_RC:-}" ]; then exit "$NODE_SHIM_RC"; fi\nprintf "%%s\\n" "$NODE_SHIM_OUT"\n' > "$T/bin/node"
  chmod +x "$T/bin"/*
  printf 'MemAvailable:    8388608 kB\n' > "$T/meminfo"

  cat > "$T/drive.sh" <<EOF
set -e
for f in common/ui common/corrections common/detect common/prompts wizard/validators wizard/whiptail \\
  wizard/manifest wizard/engine wizard/config_writer wizard/safety wizard/summary wizard/route; do
  source "$REPO/src/\$f.sh"
done
run_wizard "\$1"
EOF
  export SCRIPT_DIR="$T/repo" HOME="$T/home" SHIM_STATE="$T/state" SHIM_LOG="$T/shim.log"
  export MC_SETUP_MEMINFO="$T/meminfo" MC_SETUP_CGROUP_MEMMAX="$T/none"
  export SS_SHIM_LISTEN="" IP_SHIM_SRC="192.168.1.50"
  export NODE_SHIM_OUT='{"minecraft":"1.21.4","notices":[],"dropped":[]}'
  export TERM=xterm MC_SETUP_FORCE_TTY=1 MC_SETUP_TERM_SIZE="40 120"
  export WHIPTAIL_SHIM_REPLIES="$T/replies"
  unset NODE_SHIM_RC
  EULA=false
  : > "$SHIM_LOG"
  : > "$T/replies"
}

# Answers for the steps from the player slots to the end (whitelist no, no optional mods,
# backups yes, no restarts, no webhook, no api wrapper).
TAIL_REPLIES=$'0|A Minecraft Server\n0|normal\n1|\n0|\n0|\n1|\n0|\n1|'

# Prints the run's output followed by rc=<n>. Usage: drive <stdin-text>
drive() {
  local out rc=0
  rm -f "$T/state/whiptail.count"
  out="$(PATH="$T/bin:$PATH" EULA="$EULA" bash "$T/drive.sh" guided <<< "$1" 2>&1)" || rc=$?
  echo "$out"
  echo "rc=$rc"
}

cfg() { jq -c "$1" "$T/repo/variables.json"; }

test_guided_flow_end_to_end() {
  setup
  export NODE_SHIM_RC=1
  printf '%s\n' "0|my-world" "0|vanilla" "0|latest" "0|2G" "0|6" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "finishes without the resolver (vanilla needs none)"
  assert_eq '"my-world"' "$(cfg .INSTANCE_NAME)" "typed name"
  assert_eq 'false' "$(cfg .JAVA.SERVER.VANILLA.USE_FABRIC)" "vanilla"
  assert_eq '"latest"' "$(cfg .JAVA.SERVER.VANILLA.VERSION)" "version kept as typed"
  assert_eq '"2G"' "$(cfg .JAVA.JAVA_ARGS_CONFIG.maxMemory)" "memory"
  assert_eq '"2G"' "$(cfg .JAVA.JAVA_ARGS_CONFIG.minMemory)" "start memory equals maximum"
  assert_eq '6' "$(cfg .JAVA.SERVER.MAX_PLAYERS)" "player slots"
  assert_eq 'false' "$(cfg .JAVA.SERVER.WHITELIST)" "whitelist off"
  assert_eq 'false' "$(cfg .API_SERVER.ENABLED)" "api wrapper off"
  assert_contains "$out" "https://aka.ms/MinecraftEULA" "eula step shown"
}

test_guided_memory_above_safe_is_corrected_and_listed() {
  setup
  printf '%s\n' "0|my-world" "0|vanilla" "0|latest" "0|64G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "finishes"
  assert_eq '"6G"' "$(cfg .JAVA.JAVA_ARGS_CONFIG.maxMemory)" "lowered to the safe amount"
  assert_contains "$out" "ADJUSTED:" "correction block shown"
  assert_contains "$out" "Memory" "memory named on the summary"
  assert_contains "$out" "65536 MB" "what was asked is shown"
}

test_guided_modpack_asks_curseforge_only_then() {
  setup
  printf '%s\n' "0|my-world" "0|modpack" "0|secret-key" "0|123456" "0|4G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  export NODE_SHIM_RC=1
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "finishes"
  assert_logged "CurseForge API key" "key asked for a modpack"
  assert_logged "CurseForge pack ID" "pack asked for a modpack"
  assert_not_logged "Minecraft version" "version not asked for a modpack"
  assert_eq '"123456"' "$(jq -c .pack_id "$T/repo/src/setup/download/json/curseforge_variables.json")" "pack file written"

  setup
  printf '%s\n' "0|my-world" "0|fabric" "0|latest" "0|4G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "fabric finishes"
  assert_not_logged "CurseForge API key" "no modpack question for fabric"
  assert_logged "Minecraft version" "version asked for fabric"
  assert_missing "$T/repo/src/setup/download/json/curseforge_variables.json" "no curseforge file"
}

test_guided_rejects_existing_instance_name() {
  setup
  mkdir -p "$T/home/minecraft-server/instances/server"
  printf '%s\n' "0|server" "0|" "0|fresh" "0|vanilla" "0|latest" "0|4G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "finishes after the name is changed"
  assert_logged "already exists" "refusal shown in a message box"
  assert_eq '"fresh"' "$(cfg .INSTANCE_NAME)" "the new name is used"
  assert_exists "$T/home/minecraft-server/instances/server" "existing instance untouched"
}

test_guided_fabric_latest_uses_the_resolver() {
  setup
  export NODE_SHIM_OUT='{"minecraft":"1.21.1","notices":[{"severity":"adjusted","text":"26.3 was skipped because mod foo has no build for it; using 1.21.1."}],"dropped":["foo","bar"]}'
  printf '%s\n' "0|my-world" "0|fabric" "0|latest" "0|4G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "finishes"
  assert_eq '"1.21.1"' "$(cfg .JAVA.SERVER.VANILLA.VERSION)" "resolved version written"
  assert_eq '["foo","bar"]' "$(cfg .JAVA.SERVER.VANILLA.MODS.EXCLUDE)" "dropped mods excluded"
  assert_contains "$out" "26.3 was skipped" "notice shown as a correction"
}

test_guided_fabric_specific_version_is_used_as_given() {
  setup
  export NODE_SHIM_RC=1
  printf '%s\n' "0|my-world" "0|fabric" "0|1.20.4" "0|4G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "rc=0" "no resolver call"
  assert_eq '"1.20.4"' "$(cfg .JAVA.SERVER.VANILLA.VERSION)" "typed version kept"
}

test_guided_resolver_failure_aborts_before_changes() {
  setup
  export NODE_SHIM_RC=1
  printf '%s\n' "0|my-world" "0|fabric" "0|latest" "0|4G" "0|10" > "$T/replies"
  printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
  local out
  out="$(drive $'y\ny\n')"
  assert_contains "$out" "check your internet connection" "clear message"
  assert_contains "$out" "rc=1" "exit 1"
  assert_missing "$T/repo/variables.json" "no config"
  assert_eq "" "$(find "$T/repo" -maxdepth 1 -name ".variables*")" "no temp files"
}

test_help_texts_use_plain_language() {
  local text
  source "$REPO/src/wizard/manifest.sh"
  text="$(wizard_manifest | cut -f9,10)"
  assert_contains "$text" "memory (RAM)" "memory explained"
  assert_contains "$text" "whitelist is a list" "whitelist explained"
  if grep -qiE '\b(heap|xmx|xms|gc|rcon|jvm)\b' <<< "$text"; then
    assert_eq "no jargon" "jargon found" "help texts avoid jargon"
  else
    assert_eq ok ok "help texts avoid jargon"
  fi
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

# Starts the guided drive in its own process group, waits for the marker file, signals the
# whole group and sets SIGNAL_STATUS to the driver's wait status.
run_and_signal() { # signal marker stdin-file
  local pid
  set -m
  PATH="$T/bin:$PATH" EULA=false sig_exec bash "$T/drive.sh" guided < "$3" > "$T/out" 2>&1 &
  pid=$!
  set +m
  signal_when_started "$1" "$pid" "$2"
}

# A jq that stalls the config merge (the only call with --rawfile) once JQ_SHIM_SLEEP names a marker.
install_stalling_jq() {
  REAL_JQ="$(command -v jq)"
  export REAL_JQ
  cat > "$T/bin/jq" <<'EOF'
#!/bin/bash
case " $* " in
  *" --rawfile "*) if [ -n "${JQ_SHIM_SLEEP:-}" ]; then echo "$$" > "$JQ_SHIM_SLEEP"; for ((i = 0; i < 600; i++)); do [ -e "$JQ_SHIM_SLEEP.release" ] && break; sleep 0.1; done; fi ;;
esac
exec "$REAL_JQ" "$@"
EOF
  chmod +x "$T/bin/jq"
}

test_ctrl_c_mid_wizard_leaves_no_variables_json() {
  ! signals_unreliable ctrl_c_mid_wizard_leaves_no_variables_json || return 0
  setup
  printf '%s\n' "0|my-world" "block|" > "$T/replies"
  : > "$T/stdin"
  run_and_signal INT "$T/state/whiptail.blocked" "$T/stdin"
  assert_exists "$T/state/whiptail.blocked" "the wizard was waiting on a screen"
  assert_eq 130 "$SIGNAL_STATUS" "the run ends as interrupted"
  assert_missing "$T/repo/variables.json" "no config after Ctrl-C"
  assert_eq "" "$(find "$T/repo" -maxdepth 1 -name ".variables*")" "no temp files after Ctrl-C"
  assert_eq "gone" "$(kill -0 "$(cat "$T/state/whiptail.blocked")" 2> /dev/null && echo running || echo gone)" "no screen process left running"
}

test_interrupt_during_the_write_removes_what_this_run_created() {
  ! signals_unreliable interrupt_during_the_write_removes_what_this_run_created || return 0
  local sig status
  for sig in INT TERM; do
    (
      setup
      install_stalling_jq
      printf '%s\n' "0|my-world" "0|modpack" "0|secret-key" "0|123456" "0|4G" "0|10" > "$T/replies"
      printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
      printf 'y\ny\n' > "$T/stdin"
      export JQ_SHIM_SLEEP="$T/jq.started"
      run_and_signal "$sig" "$T/jq.started" "$T/stdin"
      status=130
      [ "$sig" = TERM ] && status=143
      assert_exists "$T/jq.started" "the write was stalled after the curseforge file ($sig)"
      assert_eq "$status" "$SIGNAL_STATUS" "the run ends as interrupted ($sig)"
      assert_missing "$T/repo/src/setup/download/json/curseforge_variables.json" "the api key file is removed ($sig)"
      assert_missing "$T/repo/variables.json" "no config ($sig)"
      assert_eq "" "$(find "$T/repo" -maxdepth 1 -name ".variables*")" "no temp files ($sig)"
      assert_eq "gone" "$(kill -0 "$(cat "$T/jq.started")" 2> /dev/null && echo running || echo gone)" "nothing left running ($sig)"
    )
  done
}

test_interrupt_keeps_a_curseforge_file_from_an_earlier_run() {
  ! signals_unreliable interrupt_keeps_a_curseforge_file_from_an_earlier_run || return 0
  local sig
  for sig in INT TERM; do
    (
      setup
      install_stalling_jq
      echo '{"pack_id":"1","api_key":"old"}' > "$T/repo/src/setup/download/json/curseforge_variables.json"
      printf '%s\n' "0|my-world" "0|fabric" "0|1.20.4" "0|4G" "0|10" > "$T/replies"
      printf '%s\n' "$TAIL_REPLIES" >> "$T/replies"
      printf 'y\ny\n' > "$T/stdin"
      export JQ_SHIM_SLEEP="$T/jq.started"
      run_and_signal "$sig" "$T/jq.started" "$T/stdin"
      assert_exists "$T/jq.started" "the write was stalled ($sig)"
      assert_file_content "$T/repo/src/setup/download/json/curseforge_variables.json" '{"pack_id":"1","api_key":"old"}' "the earlier file is untouched ($sig)"
      assert_missing "$T/repo/variables.json" "no config ($sig)"
    )
  done
}

run_tests
