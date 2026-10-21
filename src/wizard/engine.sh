#!/bin/bash
# Generic wizard engine: walks the manifest for a route, asks each step with whiptail and
# collects answers in ANSWERS, keyed by json_path (or by step id when json_path is "-").
# Expects manifest.sh, whiptail.sh and validators.sh to be sourced.
#
# engine_run <route> returns 0 when finished, 11 on Cancel, 12 when whiptail stops being
# available mid-run. Back (whiptail exit 1) returns to the previous shown step; steps hidden
# by `when` are skipped in both directions, and Back on the first shown step asks it again.
# Yes/no steps have no Back button, so Back is unavailable on them.

engine_available() { wt_available; }

# Manifest records plus the optional test-only extras named by WIZARD_MANIFEST_EXTRA.
_engine_records() {
  wizard_manifest
  if [ -n "${WIZARD_MANIFEST_EXTRA:-}" ]; then "$WIZARD_MANIFEST_EXTRA"; fi
}

# Splits a record into the global array _ENGINE_F (empty fields are kept).
_engine_split() { # record
  local rest="$1"$'\t'
  _ENGINE_F=()
  while [ -n "$rest" ]; do
    _ENGINE_F+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
}

_engine_when_met() { # when: id=value or id!=value, split at the first "="
  [ -z "$1" ] && return 0
  local lhs="${1%%=*}" rhs="${1#*=}"
  case "$lhs" in
    *"!") [ "${_ENGINE_BY_ID[${lhs%!}]-}" != "$rhs" ] ;;
    *) [ "${_ENGINE_BY_ID[$lhs]-}" = "$rhs" ] ;;
  esac
}

_engine_default() { # default_spec
  case "$1" in
    detect:*) "${1#detect:}" || true ;;
    *) printf '%s' "$1" ;;
  esac
}

# Prints the answer; returns the wt_* code. Choices arrive as tag=label pairs joined by "|".
_engine_ask() { # widget title help default
  local kind="${1%%:*}" title="$2" help="$3" default="$4" choice
  local -a pairs=() choices=()
  if [ "$1" != "$kind" ]; then
    IFS='|' read -r -a pairs <<< "${1#*:}"
    for choice in "${pairs[@]}"; do choices+=("${choice%%=*}" "${choice#*=}"); done
  fi
  case "$kind" in
    input) wt_input "$title" "$help" "$default" ;;
    password) wt_password "$title" "$help" ;;
    yesno) wt_yesno "$title" "$help" "$default" ;;
    menu) wt_menu "$title" "$help" "$default" "${choices[@]}" ;;
    radiolist) wt_radiolist "$title" "$help" "$default" "${choices[@]}" ;;
    checklist) wt_checklist "$title" "$help" "$default" "${choices[@]}" ;;
    *) echo "unknown wizard widget: $kind" >&2; return 1 ;;
  esac
}

engine_run() { # route
  local route="$1" record i=0 j count rc
  local type widget validators when title help key id
  local value current retry="" msg
  local -a steps=() vals=()
  declare -gA ANSWERS=()
  declare -gA _ENGINE_BY_ID=()

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    _engine_split "$record"
    case ",${_ENGINE_F[5]}," in *",$route,"*) steps+=("$record") ;; esac
  done < <(_engine_records)
  count="${#steps[@]}"

  while [ "$i" -lt "$count" ]; do
    engine_available || return 12
    _engine_split "${steps[i]}"
    id="${_ENGINE_F[0]}" type="${_ENGINE_F[2]}" widget="${_ENGINE_F[3]}"
    validators="${_ENGINE_F[6]}" when="${_ENGINE_F[7]}"
    title="${_ENGINE_F[8]}" help="${_ENGINE_F[9]}"
    key="${_ENGINE_F[1]}"
    [ "$key" = "-" ] && key="$id"

    if ! _engine_when_met "$when"; then
      unset "ANSWERS[$key]" "_ENGINE_BY_ID[$id]"
      i=$(( i + 1 ))
      continue
    fi

    if [ -n "$retry" ]; then
      current="$retry"
    elif [ -n "${_ENGINE_BY_ID[$id]+set}" ]; then
      current="${_ENGINE_BY_ID[$id]}"
    else
      current="$(_engine_default "${_ENGINE_F[4]}")"
    fi
    if [ "$type" = bool ]; then
      case "$current" in true | yes) current=yes ;; *) current=no ;; esac
    fi

    rc=0
    value="$(_engine_ask "$widget" "$title" "$help" "$current")" || rc=$?
    retry=""
    case "$rc" in
      0) ;;
      "$WT_BACK")
        for (( j = i - 1; j >= 0; j-- )); do
          _engine_split "${steps[j]}"
          if _engine_when_met "${_ENGINE_F[7]}"; then i="$j"; break; fi
        done
        continue
        ;;
      *) return "$WT_CANCEL" ;;
    esac

    if [ -n "$validators" ]; then
      IFS=, read -r -a vals <<< "$validators"
      if ! msg="$(run_validators "$value" "${vals[@]}")"; then
        wt_msgbox "$title" "$msg" || return "$WT_CANCEL"
        retry="$value"
        continue
      fi
    fi

    value="${value//$'\n'/ }"
    if [ "$type" = bool ]; then
      case "$value" in yes) value=true ;; *) value=false ;; esac
    fi
    ANSWERS[$key]="$value"
    _ENGINE_BY_ID[$id]="$value"
    i=$(( i + 1 ))
  done
  return 0
}
