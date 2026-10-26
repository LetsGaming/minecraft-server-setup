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
  cat > "$T/bin/node" <<'SHIM'
#!/bin/bash
[ "$1" = -v ] && { echo v20.1.0; exit 0; }
echo "node $*" >> "${SHIM_LOG:-/dev/null}"
[ -z "${NODE_SHIM_ERR:-}" ] || echo "$NODE_SHIM_ERR" >&2
if [ -n "${NODE_SHIM_RC:-}" ]; then exit "$NODE_SHIM_RC"; fi
printf '%s
' "$NODE_SHIM_OUT"
SHIM
  chmod +x "$T/bin"/*
  printf 'MemAvailable:    8388608 kB\n' > "$T/meminfo"
  : > "$T/replies"

  cat > "$T/drive.sh" <<EOF
set -e
for f in common/ui common/corrections common/detect common/prompts wizard/validators wizard/whiptail \\
  wizard/manifest wizard/engine wizard/config_writer wizard/safety wizard/summary wizard/route; do
  source "$REPO/src/\$f.sh"
done
eval "\${DRIVE_PRE:-}"
run_wizard "\$1"
if [ -n "\${DRIVE_FINAL:-}" ]; then final_screen; fi
EOF
  export SCRIPT_DIR="$T/repo" HOME="$T/home" SHIM_STATE="$T/state" SHIM_LOG="$T/shim.log"
  export MC_SETUP_MEMINFO="$T/meminfo" MC_SETUP_CGROUP_MEMMAX="$T/none"
  export SS_SHIM_LISTEN="" IP_SHIM_SRC="192.168.1.50"
  export NODE_SHIM_OUT='{"minecraft":"1.21.4","notices":[],"dropped":[]}'
  export TERM=xterm MC_SETUP_FORCE_TTY=1 MC_SETUP_TERM_SIZE="40 120"
  unset NODE_SHIM_RC NODE_SHIM_ERR VERBOSE WHIPTAIL_SHIM_REPLIES DRIVE_FINAL DRIVE_PRE
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

test_low_disk_refuses_before_anything_is_written() {
  setup
  export DRIVE_PRE='detect_disk_free_gb() { echo 2; }'
  local out route
  for route in default guided; do
    out="$(drive "$route" $'y
y
')"
    assert_contains "$out" "rc=1" "$route: exits 1"
    assert_contains "$out" "Only 2 GB is free" "$route: says how much is free"
    assert_contains "$out" "at least 5 GB" "$route: says how much is needed"
    assert_missing "$T/repo/variables.json" "$route: no config written"
  done
}

test_unknown_disk_space_only_warns() {
  setup
  export DRIVE_PRE='detect_disk_free_gb() { return 1; }'
  local out
  out="$(drive default $'y
y
')"
  assert_contains "$out" "rc=0" "route continues"
  assert_contains "$out" "Could not check the free disk space" "warns"
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

test_the_default_route_takes_the_instance_name_from_the_flag() {
  setup
  local out
  out="$(DRIVE_PRE='INSTANCE_NAME_FLAG=creative' drive default $'y\ny\n')"
  assert_contains "$out" "rc=0" "route finishes"
  assert_eq '"creative"' "$(cfg .INSTANCE_NAME)" "the flag's name is written"
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

test_resolver_failure_shows_the_resolver_message() {
  setup
  export NODE_SHIM_RC=1 NODE_SHIM_ERR="resolve_default_version: A request timed out; check your internet connection and try again."
  local out
  out="$(drive default $'y
y
')"
  assert_contains "$out" "A request timed out" "resolver message is shown"
  assert_contains "$out" "rc=1" "exit 1"
  assert_missing "$T/repo/variables.json" "no config"
}

test_verbose_shows_resolver_stderr_on_success() {
  setup
  export NODE_SHIM_ERR="resolver chatter"
  local out
  out="$(drive default $'y
y
')"
  assert_not_contains "$out" "resolver chatter" "quiet by default"
  rm -f "$T/repo/variables.json"
  export VERBOSE=true
  out="$(drive default $'y
y
')"
  assert_contains "$out" "resolver chatter" "shown with VERBOSE=true"
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

test_final_screen_says_where_backups_and_the_service_live() {
  setup
  export DRIVE_FINAL=1
  local out
  out="$(drive default $'y
y
')"
  out="${out##*Your server is set up.}"
  assert_contains "$out" "Backups: $T/home/minecraft-server/backups/server" "default backup folder"
  assert_contains "$out" 'systemd service "server"' "service named"
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

eula_rc() { # stdin-text (the word EOF means no input at all)
  local rc=0
  if [ "$1" = EOF ]; then
    ( source "$REPO/src/common/ui.sh"; source "$REPO/src/wizard/summary.sh"; EULA=false; eula_confirm ) < /dev/null > /dev/null 2>&1 || rc=$?
  else
    ( source "$REPO/src/common/ui.sh"; source "$REPO/src/wizard/summary.sh"; EULA=false; eula_confirm ) <<< "$1" > /dev/null 2>&1 || rc=$?
  fi
  echo "$rc"
}

test_eula_accepts_only_an_explicit_yes() {
  assert_eq 1 "$(eula_rc "")" "empty answer is not accepted"
  assert_eq 1 "$(eula_rc EOF)" "end of input is not accepted"
  assert_eq 1 "$(eula_rc n)" "no is not accepted"
  assert_eq 1 "$(eula_rc maybe)" "other text is not accepted"
  assert_eq 0 "$(eula_rc y)" "y is accepted"
  assert_eq 0 "$(eula_rc YES)" "YES is accepted"
}

test_wizard_apply_flags_keeps_user_flags_and_sets_modpack() {
  local out
  out="$(
    source "$REPO/src/wizard/route.sh"
    declare -A ANSWERS=([server_kind]=fabric)
    NO_START=true NO_SERVICE=false NO_BACKUP=false SETUP_API_SERVER=true EULA=false ACCEPT_ALL=false MODPACK=true
    wizard_apply_flags
    echo "$NO_START $NO_SERVICE $NO_BACKUP $SETUP_API_SERVER $EULA $ACCEPT_ALL $MODPACK"
    ANSWERS=([server_kind]=modpack [backups]=false)
    wizard_apply_flags
    echo "$MODPACK $NO_BACKUP"
    ANSWERS=([server_kind]=vanilla)
    wizard_apply_flags
    echo "$MODPACK"
  )"
  assert_eq $'true false false true true true false\ntrue true\nfalse' "$out" "flags kept, modpack follows the server type"
}

test_invalid_memory_size_falls_back_to_safe_heap_with_correction() {
  setup
  local out
  out="$(
    source "$REPO/src/common/ui.sh"; source "$REPO/src/common/corrections.sh"; source "$REPO/src/common/detect.sh"
    source "$REPO/src/wizard/safety.sh"; source "$REPO/src/wizard/route.sh"
    _wizard_choose_heap_for 1.5G; echo "$CHOSEN_HEAP_MB $(corrections_count)"
    corrections_reset
    _wizard_choose_heap_for abc; echo "$CHOSEN_HEAP_MB $(corrections_count)"
    corrections_reset
    _wizard_choose_heap_for 2G; echo "$CHOSEN_HEAP_MB $(corrections_count)"
  )"
  assert_eq $'6144 1\n6144 1\n2048 0' "$out" "bad sizes are corrected, good sizes kept"
}

test_end_of_input_at_the_summary_confirm_counts_as_no() {
  setup
  local out
  out="$(
    source "$REPO/src/common/ui.sh"; source "$REPO/src/common/corrections.sh"; source "$REPO/src/common/detect.sh"
    source "$REPO/src/common/prompts.sh"; source "$REPO/src/wizard/summary.sh"
    declare -A ANSWERS=([server_kind]=vanilla)
    EULA=false
    if MC_SETUP_FORCE_TTY=1 summary_render < /dev/null > /dev/null 2>&1; then echo YES; else echo NO; fi
  )"
  assert_eq "NO" "$out" "no answer is a no, not a yes"
}

test_failing_config_write_leaves_no_half_config() {
  setup
  local rc=0
  (
    source "$REPO/src/common/ui.sh"; source "$REPO/src/common/corrections.sh"; source "$REPO/src/common/detect.sh"
    source "$REPO/src/wizard/config_writer.sh"; source "$REPO/src/wizard/summary.sh"; source "$REPO/src/wizard/route.sh"
    config_write() { return 1; }
    declare -A ANSWERS=([server_kind]=modpack [curseforge_pack]=123 [curseforge_key]=k)
    EULA=true
    MC_SETUP_FORCE_TTY='' _wizard_confirm_and_write
  ) < /dev/null > /dev/null 2>&1 || rc=$?
  assert_eq 1 "$rc" "fails"
  assert_missing "$T/repo/variables.json" "no variables.json"
  assert_missing "$T/repo/src/setup/download/json/curseforge_variables.json" "no curseforge file"
}

main_setup() {
  setup
  cp "$REPO/main.sh" "$T/repo/"
  cp -r "$REPO/src/." "$T/repo/src/"
  local tool
  printf '#!/bin/bash\n[ "$1" = -v ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
  printf '#!/bin/bash\n[ "$1" = update ] && exit 0\nexit 100\n' > "$T/bin/apt"
  for tool in curl screen unzip cron rsync zstd setfacl ss npm systemctl service; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$tool"; done
  printf '#!/bin/bash\nprintf "nodejs:\n  Candidate: 20.1.0\n"\n' > "$T/bin/apt-cache"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/apt-get"
  chmod +x "$T/bin"/*
  mkdir -p "$T/systemd"
  printf 'ID=ubuntu\n' > "$T/os-release"
  export MC_SETUP_SYSTEMD_DIR="$T/systemd" MC_SETUP_OS_RELEASE="$T/os-release"
  cat >> "$T/repo/src/common/setup.sh" <<'EOF'
run_server_setup() { echo "PROBE NO_BACKUP=$NO_BACKUP SETUP_API_SERVER=$SETUP_API_SERVER MODPACK=$MODPACK EULA=$EULA"; [ -z "${PROBE_FAIL:-}" ] || return 3; }
run_optional_setup() { :; }
run_server_cleanup() { :; }
maybe_start_server() { :; }
snapshot_setup_state() { :; }
EOF
}

run_main_wiz() { # stdin-text, then main.sh args
  local input="$1" out rc=0
  shift
  out="$(cd "$T/repo" && PATH="$T/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin" EULA='' bash main.sh "$@" <<< "$input" 2>&1)" || rc=$?
  echo "$out"
  echo "rc=$rc"
}

test_main_default_without_terminal_needs_agree_eula() {
  main_setup
  export MC_SETUP_FORCE_TTY=
  local out
  out="$(run_main_wiz "" --default)"
  assert_contains "$out" "rc=1" "exits 1"
  assert_contains "$out" "--agree-eula" "names the flag"
  assert_missing "$T/repo/variables.json" "nothing written"
  out="$(run_main_wiz "" --default --agree-eula)"
  assert_contains "$out" "rc=0" "proceeds with the flag"
  assert_contains "$out" "PROBE" "install pipeline reached without prompts"
  assert_exists "$T/repo/variables.json" "config written"
  assert_contains "$out" "Your server is set up." "final screen shown"
}

test_main_guided_answers_survive_into_the_pipeline() {
  main_setup
  cat > "$T/replies" <<'EOF'
0|my-world
0|fabric
0|latest
0|4G
0|10
0|A Minecraft Server
0|normal
1|
0|
1|
1|
0|
1|
1|
EOF
  export WHIPTAIL_SHIM_REPLIES="$T/replies"
  local out
  out="$(run_main_wiz $'y\ny\n' --guided)"
  assert_contains "$out" "PROBE NO_BACKUP=true SETUP_API_SERVER=false MODPACK=false EULA=true" "backups answer reaches the pipeline"
}

test_main_dry_run_writes_nothing() {
  main_setup
  export MC_SETUP_FORCE_TTY=
  local out
  out="$(run_main_wiz "" --default --agree-eula --dry-run)"
  assert_contains "$out" "rc=0" "exits 0"
  assert_contains "$out" "Dry run: nothing was written or installed." "says so"
  assert_not_contains "$out" "Your server is set up." "no final screen"
  assert_not_contains "$out" "PROBE" "pipeline not started"
  assert_missing "$T/repo/variables.json" "no config"
  out="$(run_main_wiz "" --default --agree-eula --dry-run)"
  assert_contains "$out" "Dry run: nothing was written" "second run still uses the wizard"
}

test_main_dry_run_on_a_fresh_host_skips_the_version_check() {
  main_setup
  if PATH="/usr/bin:/bin" command -v node > /dev/null 2>&1; then
    skip "fresh host dry run" "this host has node on the base PATH"
    return 0
  fi
  rm -f "$T/bin/node"
  export MC_SETUP_FORCE_TTY=
  local out
  out="$(run_main_wiz "" --default --agree-eula --dry-run)"
  assert_contains "$out" "rc=0" "exits 0"
  assert_contains "$out" "Dry run: Node.js or jq is not installed yet, so the Minecraft version check was skipped." "says why"
  assert_contains "$out" "latest (not checked)" "summary shows the unchecked version"
  assert_contains "$out" "Dry run: nothing was written or installed." "normal dry-run ending"
  assert_missing "$T/repo/variables.json" "no config"
}

test_main_failure_message_is_printed_once_and_exit_code_kept() {
  main_setup
  export MC_SETUP_FORCE_TTY='' PROBE_FAIL=1
  local out
  out="$(run_main_wiz "" --default --agree-eula)"
  assert_contains "$out" "rc=3" "original exit code kept"
  assert_eq 1 "$(grep -c "Your answers are saved in variables.json" <<< "$out")" "message printed exactly once"
  assert_exists "$T/repo/variables.json" "config kept"
  unset PROBE_FAIL
  rm -f "$T/repo/variables.json"
  out="$(run_main_wiz "" --default --agree-eula)"
  assert_contains "$out" "rc=0" "success exits 0"
  assert_not_contains "$out" "Your answers are saved" "no failure message on success"
}

run_tests
