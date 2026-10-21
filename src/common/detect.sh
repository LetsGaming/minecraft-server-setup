#!/bin/bash
set -e

detect_mem_available_mb() {
  local meminfo="${MC_SETUP_MEMINFO:-/proc/meminfo}" cgroup="${MC_SETUP_CGROUP_MEMMAX:-/sys/fs/cgroup/memory.max}"
  local kb mb limit
  kb="$(awk '/^MemAvailable:/ {print $2; exit}' "$meminfo" 2>/dev/null || true)"
  mb=$(( ${kb:-0} / 1024 ))
  if [ -r "$cgroup" ]; then
    limit="$(tr -d '[:space:]' < "$cgroup")"
    if [[ "$limit" =~ ^[0-9]+$ ]] && [ $(( limit / 1048576 )) -lt "$mb" ]; then
      mb=$(( limit / 1048576 ))
    fi
  fi
  echo "$mb"
}

detect_cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

detect_disk_free_gb() { # path
  local dir="$1" kb
  while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    dir="$(dirname "$dir")"
  done
  kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 1
  echo $(( kb / 1048576 ))
}

_detect_os_field() { # key
  local file="${MC_SETUP_OS_RELEASE:-/etc/os-release}" value
  value="$(sed -n "s/^$1=//p" "$file" 2>/dev/null | head -n 1)"
  value="${value%\"}"
  echo "${value#\"}"
}

detect_os_id() { _detect_os_field ID; }
detect_os_id_like() { _detect_os_field ID_LIKE; }
detect_os_version_id() { _detect_os_field VERSION_ID; }

detect_port_free() { # port
  local port="$1"
  ! ss -ltnH 2>/dev/null | awk -v p="$port" '{n = split($4, a, ":"); if (a[n] == p) found = 1} END {exit !found}'
}

detect_next_free_port() { # start
  local port="$1"
  while ! detect_port_free "$port"; do
    port=$(( port + 1 ))
  done
  echo "$port"
}

detect_local_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

detect_instance_exists() { # name target_dir_name
  local name="$1" target="$2"
  [ -e "$HOME/$target/instances/$name" ] ||
    [ -e "$HOME/$target/scripts/$name" ] ||
    [ -e "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$name.service" ]
}

detect_free_instance_name() { # base target_dir_name
  local base="$1" target="$2" candidate="$1" n=2
  while detect_instance_exists "$candidate" "$target"; do
    candidate="$base-$n"
    n=$(( n + 1 ))
  done
  echo "$candidate"
}
