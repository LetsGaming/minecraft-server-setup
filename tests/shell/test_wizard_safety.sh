#!/bin/bash
# Safety rules. System facts come from MC_SETUP_* overrides and the ss shim.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"
source "$REPO/src/common/ui.sh"
source "$REPO/src/common/corrections.sh"
source "$REPO/src/common/detect.sh"
source "$REPO/src/wizard/safety.sh"
SHIM_BIN="$(mktemp -d)"
MEM_DIR="$(mktemp -d)"
cp "$HERE/shims/ss" "$SHIM_BIN/"
chmod +x "$SHIM_BIN/ss"
trap 'rm -rf "$SHIM_BIN" "$MEM_DIR"' EXIT
PATH="$SHIM_BIN:$PATH"

set_available_mb() {
  printf 'MemAvailable: %d kB\n' $(( $1 * 1024 )) > "$MEM_DIR/meminfo"
  export MC_SETUP_MEMINFO="$MEM_DIR/meminfo" MC_SETUP_CGROUP_MEMMAX="$MEM_DIR/absent"
}

setup_each() { corrections_reset; unset SS_SHIM_LISTEN; }

test_heap_rule_values() {
  assert_eq "1024" "$(safe_heap_mb 1536)" "1536 floors to 1024"
  assert_eq "1024" "$(safe_heap_mb 2048)" "2048"
  assert_eq "3072" "$(safe_heap_mb 4096)" "4096"
  assert_eq "6000" "$(safe_heap_mb 8000)" "8000"
  assert_eq "8192" "$(safe_heap_mb 16000)" "16000 capped"
  assert_eq "8192" "$(safe_heap_mb 64000)" "64000 capped"
  assert_eq "4G" "$(heap_to_java_size 4096)" "multiple of 1024"
  assert_eq "6000M" "$(heap_to_java_size 6000)" "not a multiple"
}

test_heap_request_above_safe_is_corrected() {
  setup_each; set_available_mb 4096
  choose_heap 6144
  assert_eq "3072" "$CHOSEN_HEAP_MB" "safe heap used"
  assert_eq "1" "$(corrections_count)" "one correction"
  local out; out="$(corrections_render)"
  assert_contains "$out" "ADJUSTED" "adjusted severity"
  assert_contains "$out" "6144" "asked value"
  assert_contains "$out" "3072" "chosen value"
  assert_contains "$out" "operating system" "reason"
}

test_heap_request_within_safe_is_kept() {
  setup_each; set_available_mb 8000
  choose_heap 2048
  assert_eq "2048" "$CHOSEN_HEAP_MB" "as requested"
  choose_heap 1024
  assert_eq "1024" "$CHOSEN_HEAP_MB" "exactly the floor"
  choose_heap ""
  assert_eq "6000" "$CHOSEN_HEAP_MB" "empty request uses safe heap"
  assert_eq "0" "$(corrections_count)" "no corrections"
}

test_heap_request_below_floor_is_corrected() {
  setup_each; set_available_mb 8000
  choose_heap 512
  assert_eq "1024" "$CHOSEN_HEAP_MB" "raised to the floor"
  assert_eq "1" "$(corrections_count)" "one correction"
  local out; out="$(corrections_render)"
  assert_contains "$out" "ADJUSTED" "adjusted severity"
  assert_contains "$out" "512 MB" "asked value"
  assert_contains "$out" "at least 1 GB" "reason"
}

test_heap_non_numeric_request_uses_safe_heap_silently() {
  setup_each; set_available_mb 8000
  local out
  out="$(choose_heap abc 2>&1)"
  assert_eq "" "$out" "nothing printed"
  choose_heap abc
  assert_eq "6000" "$CHOSEN_HEAP_MB" "safe heap"
  assert_eq "1" "$(corrections_count)" "one correction"
  assert_contains "$(corrections_render)" "abc" "text as typed"
  choose_heap "4;x"
  assert_eq "6000" "$CHOSEN_HEAP_MB" "injection-like text"
}

test_heap_overlong_request_is_invalid() {
  setup_each; set_available_mb 8000
  choose_heap 99999999999999999999
  assert_eq "6000" "$CHOSEN_HEAP_MB" "safe heap"
  assert_eq "1" "$(corrections_count)" "one correction"
  assert_eq "1024" "$(safe_heap_mb 99999999999999999999)" "helper treats as 0"
}

test_public_helpers_survive_bad_input() {
  assert_eq "1024" "$(safe_heap_mb abc)" "non-numeric available"
  assert_eq "1024" "$(safe_heap_mb "")" "empty available"
  assert_eq "1G" "$(heap_to_java_size abc)" "bad size falls back"
  assert_eq "1G" "$(heap_to_java_size "")" "empty size falls back"
  assert_eq "false" "$(heap_pretouch abc)" "bad pretouch input"
  assert_eq "3072" "$(safe_heap_mb 04096)" "leading zeros are decimal"
}

test_resourcing_is_safe() {
  local rc=0
  ( source "$REPO/src/wizard/safety.sh" && source "$REPO/src/wizard/safety.sh" ) || rc=$?
  assert_rc 0 "$rc" "sourcing twice"
}

test_low_ram_raises_warning_but_returns_value() {
  setup_each; set_available_mb 1400
  choose_heap ""
  assert_eq "1024" "$CHOSEN_HEAP_MB" "value still chosen"
  assert_eq "1" "$(corrections_count)" "one warning"
  local out; out="$(corrections_render)"
  assert_contains "$out" "WARNING" "warning severity"
  assert_contains "$out" "slow or fail" "explains the risk"
  assert_contains "$out" "1400 MB" "shows available MB"
}

test_low_ram_boundary_and_zero() {
  setup_each; set_available_mb 1535
  choose_heap ""
  assert_eq "1" "$(corrections_count)" "1535 warns"
  corrections_reset; set_available_mb 1536
  choose_heap ""
  assert_eq "0" "$(corrections_count)" "1536 does not warn"
  corrections_reset; set_available_mb 0
  choose_heap ""
  assert_eq "1024" "$CHOSEN_HEAP_MB" "zero RAM heap"
  assert_eq "1" "$(corrections_count)" "zero RAM warns"
}

test_port_default_when_free_no_correction() {
  setup_each
  export SS_SHIM_LISTEN=""
  choose_server_port
  choose_rcon_port
  assert_eq "25565" "$CHOSEN_SERVER_PORT" "server port"
  assert_eq "25575" "$CHOSEN_RCON_PORT" "rcon port"
  assert_eq "0" "$(corrections_count)" "no corrections"
}

test_port_busy_picks_next_and_warns_with_port_number() {
  setup_each
  export SS_SHIM_LISTEN="25565 25575 25576"
  choose_server_port
  choose_rcon_port
  assert_eq "25566" "$CHOSEN_SERVER_PORT" "next server port"
  assert_eq "25577" "$CHOSEN_RCON_PORT" "next rcon port"
  assert_eq "2" "$(corrections_count)" "two warnings"
  local out; out="$(corrections_render)"
  assert_contains "$out" "WARNING" "warning severity"
  assert_contains "$out" "25566" "server port number"
  assert_contains "$out" "forward on the router" "router hint"
  assert_contains "$out" "25577" "rcon port number"
  assert_contains "$out" "Remote console port (RCON)" "rcon subject"
  assert_contains "$out" "send commands to the server" "rcon plain wording"
}

test_name_collision_picks_next_and_corrects() (
  setup_each
  local d; d="$(mktemp -d)"
  export HOME="$d/home" SYSTEMD_UNIT_DIR="$d/units"
  mkdir -p "$HOME/mc/instances/alpha" "$SYSTEMD_UNIT_DIR"
  choose_instance_name beta mc
  assert_eq "beta" "$CHOSEN_INSTANCE_NAME" "free name kept"
  assert_eq "0" "$(corrections_count)" "no correction when free"
  choose_instance_name alpha mc
  assert_eq "alpha-2" "$CHOSEN_INSTANCE_NAME" "next name"
  assert_eq "1" "$(corrections_count)" "one correction"
  assert_contains "$(corrections_render)" "the name alpha is already in use" "reason"
  rm -rf "$d"
)

test_pretouch_off_for_small_heap() {
  assert_eq "false" "$(heap_pretouch 1024)" "1024"
  assert_eq "false" "$(heap_pretouch 4095)" "4095"
  assert_eq "true" "$(heap_pretouch 4096)" "4096"
  assert_eq "true" "$(heap_pretouch 8192)" "8192"
}

run_tests
