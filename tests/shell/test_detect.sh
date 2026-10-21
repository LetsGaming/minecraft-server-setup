#!/bin/bash
# Machine detectors. System facts come from MC_SETUP_* overrides and the ss/ip shims.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"
source "$REPO/src/common/detect.sh"
SHIM_BIN="$(mktemp -d)"
cp "$HERE/shims/ss" "$HERE/shims/ip" "$SHIM_BIN/"
chmod +x "$SHIM_BIN/ss" "$SHIM_BIN/ip"
trap 'rm -rf "$SHIM_BIN"' EXIT
PATH="$SHIM_BIN:$PATH"

new_tmp() { mktemp -d; }
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

test_mem_uses_lower_of_meminfo_and_cgroup() {
  local d; d="$(new_tmp)"
  printf 'MemTotal: 16384000 kB\nMemAvailable: %d kB\n' $((8000 * 1024)) > "$d/meminfo"
  echo $((2048 * 1048576)) > "$d/memmax"
  assert_eq "2048" "$(MC_SETUP_MEMINFO="$d/meminfo" MC_SETUP_CGROUP_MEMMAX="$d/memmax" detect_mem_available_mb)" "cgroup is lower"
  echo $((16000 * 1048576)) > "$d/memmax"
  assert_eq "8000" "$(MC_SETUP_MEMINFO="$d/meminfo" MC_SETUP_CGROUP_MEMMAX="$d/memmax" detect_mem_available_mb)" "meminfo is lower"
  rm -rf "$d"
}

test_mem_ignores_cgroup_max() {
  local d; d="$(new_tmp)"
  printf 'MemAvailable: %d kB\n' $((8000 * 1024)) > "$d/meminfo"
  echo max > "$d/memmax"
  assert_eq "8000" "$(MC_SETUP_MEMINFO="$d/meminfo" MC_SETUP_CGROUP_MEMMAX="$d/memmax" detect_mem_available_mb)" "max ignored"
  assert_eq "8000" "$(MC_SETUP_MEMINFO="$d/meminfo" MC_SETUP_CGROUP_MEMMAX="$d/absent" detect_mem_available_mb)" "absent ignored"
  rm -rf "$d"
}

test_port_free_detects_ipv4_and_ipv6_listeners() {
  export SS_SHIM_LISTEN="25565 [::]:25566"
  assert_rc 1 "$(rc_of detect_port_free 25565)" "25565 busy (ipv4)"
  assert_rc 1 "$(rc_of detect_port_free 25566)" "25566 busy (ipv6)"
  assert_rc 0 "$(rc_of detect_port_free 25567)" "25567 free"
  assert_rc 0 "$(rc_of detect_port_free 2556)" "prefix of busy port is free"
  assert_rc 0 "$(SS_SHIM_LISTEN="125565 255650" rc_of detect_port_free 25565)" "no substring match"
  unset SS_SHIM_LISTEN
}

test_next_free_port_skips_busy() {
  export SS_SHIM_LISTEN="25565 [::]:25566"
  assert_eq "25567" "$(detect_next_free_port 25565)" "skips both busy ports"
  assert_eq "25570" "$(detect_next_free_port 25570)" "free start returned as is"
  unset SS_SHIM_LISTEN
}

test_local_ip_from_route() {
  assert_eq "192.168.1.20" "$(IP_SHIM_SRC=192.168.1.20 detect_local_ip)" "source address"
  assert_eq "" "$(IP_SHIM_SRC='' detect_local_ip)" "empty when no route"
}

test_instance_exists_by_dir_scripts_and_unit() {
  local d; d="$(new_tmp)"
  export HOME="$d/home" SYSTEMD_UNIT_DIR="$d/units"
  mkdir -p "$HOME/mc/instances" "$HOME/mc/scripts" "$SYSTEMD_UNIT_DIR"
  assert_rc 1 "$(rc_of detect_instance_exists alpha mc)" "nothing exists"
  mkdir "$HOME/mc/instances/alpha"
  assert_rc 0 "$(rc_of detect_instance_exists alpha mc)" "instance dir"
  rmdir "$HOME/mc/instances/alpha"
  mkdir "$HOME/mc/scripts/alpha"
  assert_rc 0 "$(rc_of detect_instance_exists alpha mc)" "scripts dir"
  rmdir "$HOME/mc/scripts/alpha"
  : > "$SYSTEMD_UNIT_DIR/alpha.service"
  assert_rc 0 "$(rc_of detect_instance_exists alpha mc)" "unit file"
  rm -rf "$d"
}

test_free_instance_name_sequence() {
  local d; d="$(new_tmp)"
  export HOME="$d/home" SYSTEMD_UNIT_DIR="$d/units"
  mkdir -p "$HOME/mc/instances" "$SYSTEMD_UNIT_DIR"
  assert_eq "server" "$(detect_free_instance_name server mc)" "base free"
  mkdir "$HOME/mc/instances/server"
  assert_eq "server-2" "$(detect_free_instance_name server mc)" "second"
  mkdir "$HOME/mc/instances/server-2"
  assert_eq "server-3" "$(detect_free_instance_name server mc)" "third"
  rm -rf "$d"
}

test_disk_free_walks_up_to_existing_parent() {
  local d out; d="$(new_tmp)"
  out="$(detect_disk_free_gb "$d/does/not/exist")"
  assert_rc 0 "$(rc_of eval '[[ "'"$out"'" =~ ^[0-9]+$ ]]')" "integer GiB from missing path"
  assert_eq "$(detect_disk_free_gb "$d")" "$out" "same as nearest existing parent"
  rm -rf "$d"
}

test_disk_free_fails_when_it_cannot_be_determined() {
  local out rc=0
  out="$(df() { return 1; }; detect_disk_free_gb /tmp)" || rc=$?
  assert_eq "1" "$rc" "fails"
  assert_eq "" "$out" "prints nothing"
}

test_os_id_like() {
  local d; d="$(new_tmp)"
  printf 'ID=linuxmint
ID_LIKE="ubuntu debian"
' > "$d/os"
  assert_eq "ubuntu debian" "$(MC_SETUP_OS_RELEASE="$d/os" detect_os_id_like)" "id_like without quotes"
  rm -rf "$d"
}

test_os_release_fields() {
  local d; d="$(new_tmp)"
  printf 'NAME="Ubuntu"\nVERSION_ID="22.04"\nID=ubuntu\n' > "$d/os"
  assert_eq "ubuntu" "$(MC_SETUP_OS_RELEASE="$d/os" detect_os_id)" "id"
  assert_eq "22.04" "$(MC_SETUP_OS_RELEASE="$d/os" detect_os_version_id)" "version id"
  rm -rf "$d"
}

run_tests
