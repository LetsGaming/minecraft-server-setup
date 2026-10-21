#!/bin/bash
set -e

validate_port() { # value
  if [[ "$1" =~ ^[0-9]+$ ]] && [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
    return 0
  fi
  echo "'$1' is not a valid port. A port must be a number from 1 to 65535, for example 25565."
  return 1
}

validate_memory_size() { # value
  local value="$1" amount unit mb
  if [[ "$value" =~ ^[0-9]+[gm]$ ]]; then
    echo "'$value' needs a capital letter. Write the size like ${value^^}."
    return 1
  fi
  if ! [[ "$value" =~ ^[0-9]+[GM]$ ]] || [ "${#value}" -gt 7 ]; then
    echo "'$value' is not a valid memory size. Use a number followed by G or M, for example 4G or 2048M."
    return 1
  fi
  amount="${value%?}"
  unit="${value: -1}"
  mb=$(( 10#$amount ))
  [ "$unit" = G ] && mb=$(( mb * 1024 ))
  if [ "$mb" -lt 512 ]; then
    echo "'$value' is too little memory. Use at least 512M (for example 2G)."
    return 1
  fi
  return 0
}

validate_int_range() { # value min max
  local value="$1" min="$2" max="$3"
  if [[ "$value" =~ ^[0-9]+$ ]] && [ "${#value}" -le 9 ] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
    return 0
  fi
  echo "'$value' is out of range. Enter a whole number from $min to $max."
  return 1
}

validate_instance_name() { # value
  if [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    return 0
  fi
  echo "'$1' is not a valid name. Use only letters, numbers, hyphens and underscores, with no spaces (for example my-server)."
  return 1
}

validate_instance_unused() { # value
  local target
  target="$(jq -r '.TARGET_DIR_NAME // "minecraft-server"' "${SCRIPT_DIR:-.}/variables.example.json" 2>/dev/null | tr -d '\r')" || target=""
  [ -n "$target" ] || target=minecraft-server
  if detect_instance_exists "$1" "$target"; then
    echo "A server named '$1' already exists on this machine. Pick a different name; the existing server is not touched."
    return 1
  fi
  return 0
}

validate_free_port() { # value
  local msg
  if ! msg="$(validate_port "$1")"; then
    echo "$msg"
    return 1
  fi
  if detect_port_free "$1"; then
    return 0
  fi
  echo "Port $1 is already in use by another program. Pick a different port, for example $(( $1 + 1 ))."
  return 1
}

validate_min_disk_gb() { # path gb
  local free
  free="$(detect_disk_free_gb "$1")"
  if [ "$free" -ge "$2" ]; then
    return 0
  fi
  echo "Only ${free} GB free at $1, but at least $2 GB is needed. Free up space or choose another location."
  return 1
}

validate_nonempty() { # value
  if [[ "$1" =~ [^[:space:]] ]]; then
    return 0
  fi
  echo "This cannot be empty. Please enter a value."
  return 1
}

validate_one_of() { # value choice...
  local value="$1" choice list=""
  shift
  for choice in "$@"; do
    [ "$value" = "$choice" ] && return 0
    list="${list:+$list, }$choice"
  done
  echo "'$value' is not one of the choices. Pick one of: $list."
  return 1
}

validate_webhook_url() { # value
  if [ -z "$1" ] || [[ "$1" =~ ^https://[^[:space:]]+$ ]]; then
    return 0
  fi
  echo "The webhook address must start with https:// (or leave it empty to skip notifications)."
  return 1
}

validate_curseforge_pack_id() { # value
  if [[ "$1" =~ ^[0-9]+$ ]] && [ "${#1}" -le 12 ] && [ $(( 10#$1 )) -gt 0 ]; then
    return 0
  fi
  echo "'$1' is not a valid CurseForge pack ID. It must be a positive whole number, like 123456."
  return 1
}

run_validators() { # value name[:arg[:arg]]...
  local value="$1" spec msg
  local -a parts
  shift
  for spec in "$@"; do
    IFS=: read -r -a parts <<< "$spec"
    if ! msg="$("${parts[0]}" "$value" "${parts[@]:1}")"; then
      echo "$msg"
      return 1
    fi
  done
  return 0
}
