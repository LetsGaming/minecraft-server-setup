#!/bin/bash
# Safe defaults for heap, ports and instance name. The choose_* functions set CHOSEN_*
# globals and must be called directly (not in $(...)) so their corrections are kept.
# Expects ui.sh, corrections.sh and detect.sh to be sourced.

readonly HEAP_CAP_MB=8192
readonly HEAP_FLOOR_MB=1024
readonly HEAP_RESERVE_MIN_MB=1024
readonly HEAP_RESERVE_PERCENT=25
readonly LOW_RAM_WARNING_MB=1536
readonly PRETOUCH_MIN_HEAP_MB=4096
readonly DEFAULT_SERVER_PORT=25565
readonly DEFAULT_RCON_PORT=25575

CHOSEN_HEAP_MB=""
CHOSEN_SERVER_PORT=""
CHOSEN_RCON_PORT=""
CHOSEN_INSTANCE_NAME=""

safe_heap_mb() { # available_mb
  local available="$1" reserve heap
  reserve=$(( available * HEAP_RESERVE_PERCENT / 100 ))
  [ "$reserve" -ge "$HEAP_RESERVE_MIN_MB" ] || reserve="$HEAP_RESERVE_MIN_MB"
  heap=$(( available - reserve ))
  [ "$heap" -le "$HEAP_CAP_MB" ] || heap="$HEAP_CAP_MB"
  [ "$heap" -ge "$HEAP_FLOOR_MB" ] || heap="$HEAP_FLOOR_MB"
  echo "$heap"
}

heap_to_java_size() { # mb
  if [ $(( $1 % 1024 )) -eq 0 ]; then
    echo "$(( $1 / 1024 ))G"
  else
    echo "${1}M"
  fi
}

heap_pretouch() { # heap_mb
  if [ "$1" -ge "$PRETOUCH_MIN_HEAP_MB" ]; then
    echo true
  else
    echo false
  fi
}

choose_heap() { # requested_mb|""
  local requested="${1:-}" available safe
  available="$(detect_mem_available_mb)"
  safe="$(safe_heap_mb "$available")"
  if [ -z "$requested" ]; then
    CHOSEN_HEAP_MB="$safe"
  elif [ "$requested" -gt "$safe" ]; then
    CHOSEN_HEAP_MB="$safe"
    correction_add adjusted "Memory" "${requested} MB" "${safe} MB" \
      "leaves room for the operating system"
  elif [ "$requested" -lt "$HEAP_FLOOR_MB" ]; then
    CHOSEN_HEAP_MB="$HEAP_FLOOR_MB"
  else
    CHOSEN_HEAP_MB="$requested"
  fi
  if [ "$available" -lt "$LOW_RAM_WARNING_MB" ]; then
    correction_add warning "Low memory" "-" "${CHOSEN_HEAP_MB} MB" \
      "only ${available} MB of RAM is available, so the server may be slow or fail"
  fi
}

choose_server_port() {
  local port="$DEFAULT_SERVER_PORT"
  if detect_port_free "$port"; then
    CHOSEN_SERVER_PORT="$port"
    return 0
  fi
  CHOSEN_SERVER_PORT="$(detect_next_free_port $(( port + 1 )))"
  correction_add warning "Server port" "$port" "$CHOSEN_SERVER_PORT" \
    "port $port is already in use; $CHOSEN_SERVER_PORT is the port to forward on the router and give to friends"
}

choose_rcon_port() {
  local port="$DEFAULT_RCON_PORT"
  if detect_port_free "$port"; then
    CHOSEN_RCON_PORT="$port"
    return 0
  fi
  CHOSEN_RCON_PORT="$(detect_next_free_port $(( port + 1 )))"
  correction_add warning "RCON port" "$port" "$CHOSEN_RCON_PORT" \
    "port $port is already in use, so port $CHOSEN_RCON_PORT is used instead"
}

choose_instance_name() { # base target_dir_name
  CHOSEN_INSTANCE_NAME="$(detect_free_instance_name "$1" "$2")"
  if [ "$CHOSEN_INSTANCE_NAME" != "$1" ]; then
    correction_add adjusted "Instance name" "$1" "$CHOSEN_INSTANCE_NAME" \
      "an instance named $1 already exists"
  fi
}
