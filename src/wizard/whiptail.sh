#!/bin/bash
set -e

WT_BACK=10
WT_CANCEL=11
WT_MIN_COLS=70
WT_MIN_ROWS=20

# Prints "rows cols" only when the size is really known.
_wt_real_size() {
  local size
  if [ -n "${MC_SETUP_TERM_SIZE:-}" ]; then
    size="$MC_SETUP_TERM_SIZE"
  else
    size="$(stty size 2>/dev/null)" || return 1
  fi
  [[ "$size" =~ ^[0-9]+[[:space:]][0-9]+$ ]] && [ "${size%% *}" -gt 0 ] || return 1
  echo "$size"
}

_wt_term_size() { # prints "rows cols", falling back to 24 80
  _wt_real_size || echo "24 80"
}

wt_available() {
  local size
  command -v whiptail >/dev/null 2>&1 || return 1
  [ -n "${TERM:-}" ] && [ "$TERM" != dumb ] || return 1
  [ "${MC_SETUP_FORCE_TTY:-}" = 1 ] || [ -t 2 ] || return 1
  size="$(_wt_real_size)" || return 1
  [ "${size#* }" -ge "$WT_MIN_COLS" ] && [ "${size%% *}" -ge "$WT_MIN_ROWS" ]
}

# Sets WT_H, WT_W and WT_LIST_H for a box showing the given text and list rows.
_wt_dims() { # text [list_rows]
  local rows cols text_lines list_rows="${2:-0}"
  read -r rows cols <<< "$(_wt_term_size)"
  WT_W=$(( cols - 6 ))
  [ "$WT_W" -gt 78 ] && WT_W=78
  [ "$WT_W" -lt 60 ] && WT_W=60
  text_lines="$(printf '%s\n' "$1" | wc -l)"
  text_lines=$(( text_lines + ${#1} / (WT_W - 6) ))
  WT_LIST_H="$list_rows"
  WT_H=$(( text_lines + list_rows + 8 ))
  [ "$WT_H" -lt 10 ] && WT_H=10
  [ "$WT_H" -gt $(( rows - 2 )) ] && WT_H=$(( rows - 2 ))
  [ "$WT_H" -lt 10 ] && WT_H=10
  if [ "$list_rows" -gt 0 ]; then
    WT_LIST_H=$(( WT_H - text_lines - 8 ))
    [ "$WT_LIST_H" -gt "$list_rows" ] && WT_LIST_H="$list_rows"
    [ "$WT_LIST_H" -lt 3 ] && WT_LIST_H=3
  fi
  return 0
}

# Runs whiptail with the screen on stderr and the answer on fd 3; prints the answer and
# returns the raw whiptail exit code.
_wt_run() {
  local out rc=0
  out="$(whiptail --output-fd 3 "$@" 3>&1 1>&2)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then printf '%s
' "$out"; fi
  return "$rc"
}

_wt_map() { # raw whiptail exit code
  case "$1" in
    0) return 0 ;;
    1) return "$WT_BACK" ;;
    *) return "$WT_CANCEL" ;;
  esac
}

wt_input() { # title text default
  local rc=0
  _wt_dims "$2"
  _wt_run --title "$1" --cancel-button Back --inputbox "$2" "$WT_H" "$WT_W" "$3" || rc=$?
  _wt_map "$rc"
}

wt_password() { # title text
  local rc=0
  _wt_dims "$2"
  _wt_run --title "$1" --cancel-button Back --passwordbox "$2" "$WT_H" "$WT_W" || rc=$?
  _wt_map "$rc"
}

wt_yesno() { # title text default(yes|no)
  local rc=0 flags=()
  [ "${3:-yes}" = no ] && flags=(--defaultno)
  _wt_dims "$2"
  whiptail "${flags[@]}" --title "$1" --yesno "$2" "$WT_H" "$WT_W" 1>&2 || rc=$?
  case "$rc" in
    0) echo yes; return 0 ;;
    1) echo no; return 0 ;;
    *) return "$WT_CANCEL" ;;
  esac
}

wt_msgbox() { # title text
  local rc=0
  _wt_dims "$2"
  whiptail --title "$1" --msgbox "$2" "$WT_H" "$WT_W" 1>&2 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  return "$WT_CANCEL"
}

wt_menu() { # title text default tag label...
  local title="$1" text="$2" default="$3" rc=0
  shift 3
  _wt_dims "$text" $(( $# / 2 ))
  _wt_run --title "$title" --cancel-button Back --default-item "$default" \
    --menu "$text" "$WT_H" "$WT_W" "$WT_LIST_H" "$@" || rc=$?
  _wt_map "$rc"
}

wt_radiolist() { # title text default tag label...
  local title="$1" text="$2" default="$3" rc=0 items=()
  shift 3
  while [ "$#" -ge 2 ]; do
    if [ "$1" = "$default" ]; then items+=("$1" "$2" on); else items+=("$1" "$2" off); fi
    shift 2
  done
  _wt_dims "$text" $(( ${#items[@]} / 3 ))
  _wt_run --title "$title" --cancel-button Back \
    --radiolist "$text" "$WT_H" "$WT_W" "$WT_LIST_H" "${items[@]}" || rc=$?
  _wt_map "$rc"
}

# defaults is a space-separated list of tags that start checked; prints one chosen tag per line.
wt_checklist() { # title text defaults tag label...
  local title="$1" text="$2" defaults=" $3 " rc=0 items=()
  shift 3
  while [ "$#" -ge 2 ]; do
    if [[ "$defaults" == *" $1 "* ]]; then items+=("$1" "$2" on); else items+=("$1" "$2" off); fi
    shift 2
  done
  _wt_dims "$text" $(( ${#items[@]} / 3 ))
  _wt_run --title "$title" --cancel-button Back --separate-output \
    --checklist "$text" "$WT_H" "$WT_W" "$WT_LIST_H" "${items[@]}" || rc=$?
  _wt_map "$rc"
}
