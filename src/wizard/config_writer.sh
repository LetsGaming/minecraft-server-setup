#!/bin/bash
# Wizard config writer: turns the engine's ANSWERS into variables.json (merged over
# variables.example.json) and the optional CurseForge credentials file.
# Expects manifest.sh to be sourced and SCRIPT_DIR to point at the repo root.
# Secrets never travel on a command line: jq reads them from a 0600 file or from $ENV.

_CW_PSEUDO_IDS=" server_kind memory backups optional_mods curseforge_key curseforge_pack "

# Prints the json_path<TAB>type pairs of the manifest, one per line.
_cw_types() {
  local record rest path type
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    rest="${record#*$'\t'}"
    path="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    type="${rest%%$'\t'*}"
    [ "$path" = "-" ] || printf '%s\t%s\n' "$path" "$type"
  done < <(wizard_manifest)
}

_cw_rand_hex() { # bytes
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# Appends one json_path<TAB>type<TAB>value line to the assignment file.
_cw_emit() { # path type value
  local value="${3//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$1" "$2" "$value" >> "$_CW_ASSIGN"
}

_cw_has_tag() { # list tag
  case " ${1//[,\"]/ } " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

_cw_check_target() { # out_path
  if [ -e "$1" ] || [ -L "$1" ]; then
    echo "Refusing to overwrite existing file: $1" >&2
    return 1
  fi
  [ -d "$(dirname "$1")" ] || { echo "Directory does not exist: $(dirname "$1")" >&2; return 1; }
}

config_write() { # out_path
  local out="$1" example="${SCRIPT_DIR:-.}/variables.example.json"
  local dir tmp key type value kind old_umask rc=0
  local -A types=() generated=(
    [JAVA.SERVER.PORT]=number
    [JAVA.SERVER.VANILLA.MODS.EXCLUDE]=list
    [JAVA.JAVA_ARGS_CONFIG.g1gc.alwaysPreTouch]=bool
  )
  _cw_check_target "$out" || return 1
  [ -f "$example" ] || { echo "Missing $example" >&2; return 1; }
  dir="$(dirname "$out")"

  old_umask="$(umask)"
  umask 077
  tmp="$(mktemp "$dir/.variables.json.XXXXXX")" || { umask "$old_umask"; return 1; }
  _CW_ASSIGN="$(mktemp "$dir/.variables.assign.XXXXXX")" || { rm -f "$tmp"; umask "$old_umask"; return 1; }

  while IFS=$'\t' read -r key type; do types["$key"]="$type"; done < <(_cw_types)

  kind="${ANSWERS[server_kind]-}"
  for key in "${!ANSWERS[@]}"; do
    case "$_CW_PSEUDO_IDS" in *" $key "*) continue ;; esac
    value="${ANSWERS[$key]}"
    type="${types[$key]-${generated[$key]-string}}"
    [ "$kind" = modpack ] && [ "$key" = JAVA.SERVER.VANILLA.VERSION ] && continue
    [ "$key" = JAVA.SERVER.PORT ] && [ "$value" = 25565 ] && continue
    if [ -z "$value" ] && [ "$type" != string ] && [ "$type" != list ]; then continue; fi
    _cw_emit "$key" "$type" "$value"
  done

  case "$kind" in
    fabric) _cw_emit JAVA.SERVER.VANILLA.USE_FABRIC bool true ;;
    vanilla) _cw_emit JAVA.SERVER.VANILLA.USE_FABRIC bool false ;;
  esac
  if [ -n "${ANSWERS[memory]-}" ]; then
    _cw_emit JAVA.JAVA_ARGS_CONFIG.minMemory string "${ANSWERS[memory]}"
    _cw_emit JAVA.JAVA_ARGS_CONFIG.maxMemory string "${ANSWERS[memory]}"
  fi
  if _cw_has_tag "${ANSWERS[optional_mods]-}" optional; then
    _cw_emit JAVA.SERVER.VANILLA.MODS.OPTIONAL_MODS bool true
  fi

  [ -n "${ANSWERS[NOTIFICATIONS.WEBHOOK_URL]+x}" ] || _cw_emit NOTIFICATIONS.WEBHOOK_URL string ""
  [ -n "${ANSWERS[SERVER_CONTROL.RCON_PASSWORD]+x}" ] || _cw_emit SERVER_CONTROL.RCON_PASSWORD string ""
  if [ -z "${ANSWERS[API_SERVER.API_KEY]-}" ]; then
    if [ "${ANSWERS[API_SERVER.ENABLED]-}" = true ]; then
      _cw_emit API_SERVER.API_KEY string "$(_cw_rand_hex 32)"
    else
      _cw_emit API_SERVER.API_KEY string ""
    fi
  fi

  jq --rawfile ans "$_CW_ASSIGN" '
    def conv($t; $v):
      if $t == "number" then ($v | tonumber)
      elif $t == "bool" then (if $v == "true" then true elif $v == "false" then false else error("not a boolean: " + $v) end)
      elif $t == "list" then ($v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))
      else $v end;
    reduce ($ans | split("\n")[] | select(length > 0) | split("\t")) as $r
      (.; setpath($r[0] | split("."); conv($r[1]; $r[2:] | join("\t"))))
  ' "$example" > "$tmp" && jq -e . "$tmp" > /dev/null || rc=1

  rm -f "$_CW_ASSIGN"
  unset _CW_ASSIGN
  if [ "$rc" -eq 0 ]; then
    mv "$tmp" "$out" || rc=1
  fi
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; echo "Could not write $out" >&2; }
  umask "$old_umask"
  return "$rc"
}

config_write_curseforge() { # out_path
  local out="$1" dir tmp rc=0 old_umask
  [ -n "${ANSWERS[curseforge_pack]-}" ] || [ -n "${ANSWERS[curseforge_key]-}" ] || return 0
  _cw_check_target "$out" || return 1
  dir="$(dirname "$out")"
  old_umask="$(umask)"
  umask 077
  tmp="$(mktemp "$dir/.curseforge.json.XXXXXX")" || { umask "$old_umask"; return 1; }
  CW_PACK="${ANSWERS[curseforge_pack]-}" CW_KEY="${ANSWERS[curseforge_key]-}" \
    jq -n '{pack_id: $ENV.CW_PACK, api_key: $ENV.CW_KEY}' > "$tmp" && jq -e . "$tmp" > /dev/null || rc=1
  if [ "$rc" -eq 0 ]; then
    mv "$tmp" "$out" || rc=1
  fi
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; echo "Could not write $out" >&2; }
  umask "$old_umask"
  return "$rc"
}
