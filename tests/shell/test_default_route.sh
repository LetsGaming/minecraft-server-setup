#!/bin/bash
# Default and Guided routes end to end through run_wizard. System facts and the Node
# resolver are shimmed; stdin stands in for the keyboard.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/repo/src/setup/download/json" "$T/bin" "$T/home" "$T/state"
  cp "$REPO/variables.example.json" "$T/repo/"
  cp "$HERE"/shims/{ss,ip,whiptail} "$T/bin/"
  printf '#!/bin/bash\nif [ -n "${NODE_SHIM_RC:-}" ]; then exit "$NODE_SHIM_RC"; fi\nprintf "%%s\\n" "$NODE_SHIM_OUT"\n' > "$T/bin/node"
  chmod +x "$T/bin"/*
  printf 'MemAvailable:    8388608 kB\n' > "$T/meminfo"
  : > "$T/replies"

  cat > "$T/drive.sh" <<EOF
set -e
for f in common/ui common/corrections common/detect common/prompts wizard/validators wizard/whiptail \\
  wizard/manifest wizard/engine wizard/config_writer wizard/safety wizard/summary wizard/route; do
  source "$REPO/src/\$f.sh"
done
run_wizard "\$1"
if [ -n "\${DRIVE_FINAL:-}" ]; then final_screen; fi
EOF
  export SCRIPT_DIR="$T/repo" HOME="$T/home" SHIM_STATE="$T/state" SHIM_LOG="$T/shim.log"
  export MC_SETUP_MEMINFO="$T/meminfo" MC_SETUP_CGROUP_MEMMAX="$T/none"
  export SS_SHIM_LISTEN="" IP_SHIM_SRC="192.168.1.50"
  export NODE_SHIM_OUT='{"minecraft":"1.21.4","notices":[],"dropped":[]}'
  export TERM=xterm MC_SETUP_FORCE_TTY=1 MC_SETUP_TERM_SIZE="40 120"
  unset NODE_SHIM_RC WHIPTAIL_SHIM_REPLIES DRIVE_FINAL
  EULA=false
  : > "$SHIM_LOG"
}

# Prints the run's output followed by rc=<n>. Usage: drive <route> <stdin-text>
drive() {
  local out rc=0
  out="$(PATH="$T/bin:$PATH" EULA="$EULA" bash "$T/drive.sh" "$1" <<< "$2" 2>&1)" || rc=$?
  echo "$out"
  echo "rc=$rc"
}

cfg() { jq -c "$1" "$T/repo/variables.json"; }

test_default_route_writes_expected_config() {
  setup
  local out
  out="$(drive default $'y\ny\n')"
  assert_contains "$out" "rc=0" "route finishes"
  assert_exists "$T/repo/variables.json" "config written"
  assert_eq '"server"' "$(cfg .INSTANCE_NAME)" "name is server"
  assert_eq '"1.21.4"' "$(cfg .JAVA.SERVER.VANILLA.VERSION)" "version comes from the resolver"
  assert_eq 'true' "$(cfg .JAVA.SERVER.VANILLA.USE_FABRIC)" "fabric is on"
  assert_eq '25565' "$(cfg .JAVA.SERVER.PORT)" "port stays at the default when free"
  assert_eq 'true' "$(cfg .JAVA.SERVER.VANILLA.MODS.PERFORMANCE_MODS)" "performance mods on"
  assert_eq 'true' "$(cfg .JAVA.SERVER.VANILLA.MODS.UTILITY_MODS)" "utility mods on"
  assert_eq 'false' "$(cfg .JAVA.SERVER.VANILLA.MODS.OPTIONAL_MODS)" "optional mods off"
  assert_eq 'false' "$(cfg .SERVER_CONTROL.USE_RCON)" "remote console stays off"
  assert_eq 'false' "$(cfg .API_SERVER.ENABLED)" "api wrapper off"
  assert_eq '"6G"' "$(cfg .JAVA.JAVA_ARGS_CONFIG.maxMemory)" "memory leaves room for the system"
  assert_contains "$out" "https://aka.ms/MinecraftEULA" "eula url shown"
}

test_default_route_excludes_dropped_mods() {
  setup
  export NODE_SHIM_OUT='{"minecraft":"1.21.1","notices":[{"severity":"adjusted","text":"26.3 was skipped because mod foo has no build for it; using 1.21.1."}],"dropped":["foo","bar"]}'
  local out
  out="$(drive default $'y\ny\n')"
  assert_eq '["foo","bar"]' "$(cfg .JAVA.SERVER.VANILLA.MODS.EXCLUDE)" "dropped mods are excluded"
  assert_contains "$out" "26.3 was skipped" "resolver notice is shown on the summary"
}

test_default_route_declined_changes_nothing() {
  setup
  local out
  out="$(drive default $'n\n')"
  assert_contains "$out" "rc=0" "exit 0"
  assert_contains "$out" "Nothing was changed." "says so"
  assert_missing "$T/repo/variables.json" "no config"
}

test_eula_requires_explicit_yes() {
  setup
  local out
  out="$(drive default $'y\nn\n')"
  assert_contains "$out" "rc=0" "exit 0"
  assert_missing "$T/repo/variables.json" "no config without the eula"
  setup
  EULA=true
  out="$(drive default $'y\n')"
  assert_exists "$T/repo/variables.json" "eula flag answers yes without asking"
}

test_default_route_without_terminal_and_eula_flag_does_not_ask() {
  setup
  export MC_SETUP_FORCE_TTY=
  EULA=true
  local out
  out="$(drive default "")"
  assert_contains "$out" "rc=0" "exit 0"
  assert_exists "$T/repo/variables.json" "config written without any question"
}

test_busy_port_and_low_ram_corrections_listed_on_summary() {
  setup
  export SS_SHIM_LISTEN="25565"
  printf 'MemAvailable:    1048576 kB\n' > "$T/meminfo"
  local out
  out="$(drive default $'n\n')"
  assert_contains "$out" "Server port" "port correction listed"
  assert_contains "$out" "25566" "next free port named"
  assert_contains "$out" "Low memory" "low memory warning listed"
  assert_contains "$out" "WARNING:" "prefix survives without colour"
  assert_not_contains "$out" "RCON" "no jargon"
  out="$(drive default $'y\ny\n')"
  assert_eq '25566' "$(cfg .JAVA.SERVER.PORT)" "chosen port written"
}

test_name_collision_uses_next_name() {
  setup
  mkdir -p "$T/home/minecraft-server/instances/server"
  local out
  out="$(drive default $'y\ny\n')"
  assert_contains "$out" "server-2" "new name shown"
  assert_contains "$out" "Instance name" "correction listed"
  assert_eq '"server-2"' "$(cfg .INSTANCE_NAME)" "next free name written"
  assert_exists "$T/home/minecraft-server/instances/server" "existing instance untouched"
}

test_existing_variables_json_is_never_overwritten() {
  setup
  echo '{"keep":"me"}' > "$T/repo/variables.json"
  local out
  out="$(drive default $'y\ny\n')"
  assert_contains "$out" "variables.json already exists" "clear message"
  assert_contains "$out" "rc=1" "exit 1"
  assert_file_content "$T/repo/variables.json" '{"keep":"me"}' "file untouched"
  out="$(drive guided $'y\ny\n')"
  assert_contains "$out" "rc=1" "guided is guarded as well"
  assert_file_content "$T/repo/variables.json" '{"keep":"me"}' "file still untouched"
}

test_resolver_failure_aborts_before_changes() {
  setup
  export NODE_SHIM_RC=1
  local out
  out="$(drive default $'y\ny\n')"
  assert_contains "$out" "check your internet connection" "clear message"
  assert_contains "$out" "rc=1" "exit 1"
  assert_missing "$T/repo/variables.json" "no config"
}

test_cancelled_guided_changes_nothing() {
  setup
  printf '255|\n' > "$T/replies"
  export WHIPTAIL_SHIM_REPLIES="$T/replies"
  local out
  out="$(drive guided "")"
  assert_contains "$out" "rc=0" "exit 0"
  assert_contains "$out" "Nothing was changed." "says so"
  assert_missing "$T/repo/variables.json" "no config"
}

test_guided_falls_back_to_default_when_whiptail_unavailable() {
  setup
  export TERM=dumb
  local out
  out="$(drive guided $'y\ny\n')"
  assert_contains "$out" "quick setup is used instead" "notice printed"
  assert_contains "$out" "rc=0" "finishes"
  assert_eq '"1.21.4"' "$(cfg .JAVA.SERVER.VANILLA.VERSION)" "default answers used"
}

test_guided_applies_safety_rules_to_typed_answers() {
  setup
  export SS_SHIM_LISTEN="25565"
  cat > "$T/replies" <<'EOF'
0|my-world
0|fabric
0|latest
0|64G
0|10
0|A Minecraft Server
0|normal
1|
0|
0|
1|
0|
1|
EOF
  export WHIPTAIL_SHIM_REPLIES="$T/replies"
  local out
  out="$(drive guided $'y\ny\n')"
  assert_contains "$out" "rc=0" "finishes"
  assert_eq '"my-world"' "$(cfg .INSTANCE_NAME)" "typed name kept"
  assert_eq '"6G"' "$(cfg .JAVA.JAVA_ARGS_CONFIG.maxMemory)" "oversized memory lowered"
  assert_eq '25566' "$(cfg .JAVA.SERVER.PORT)" "busy port replaced"
  assert_contains "$out" "Memory" "memory correction listed"
}

test_final_screen_shows_port_and_forwarding_notice() {
  setup
  export SS_SHIM_LISTEN="25565" DRIVE_FINAL=1
  local out
  out="$(drive default $'y\ny\n')"
  out="${out##*Your server is set up.}"
  assert_contains "$out" "25566" "actual port shown"
  assert_contains "$out" "router" "router mentioned"
  assert_contains "$out" "forward" "forwarding mentioned"
  assert_contains "$out" "192.168.1.50" "local address shown"
  assert_contains "$out" "$T/home/minecraft-server/instances/server" "location shown"
  assert_contains "$out" "Server port" "corrections repeated"
}

test_final_screen_without_ip_names_the_local_address() {
  setup
  export IP_SHIM_SRC="" DRIVE_FINAL=1
  local out
  out="$(drive default $'y\ny\n')"
  assert_contains "$out" "local address and port 25565" "falls back to wording"
}

test_failure_screen_keeps_variables_json() {
  setup
  echo '{}' > "$T/repo/variables.json"
  local out
  out="$(
    source "$REPO/src/wizard/summary.sh"
    ROUTE=default
    failure_screen
    failure_screen
  )"
  assert_eq "Your answers are saved in variables.json. Run again to retry, or delete it to start over." "$out" "printed once"
  assert_exists "$T/repo/variables.json" "config kept"
  out="$(source "$REPO/src/wizard/summary.sh"; ROUTE=power; failure_screen)"
  assert_eq "" "$out" "silent for the power route"
}

run_tests
