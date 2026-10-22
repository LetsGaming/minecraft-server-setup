#!/bin/bash
# Which archive tiers a run owes. Pure: no clock, no I/O beyond the flag files,
# so tests can feed any date.

if [[ -n "${_BK_SCHEDULE_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_BK_SCHEDULE_LOADED=1

# bk_due_tiers <YYYY-MM-DD> <dow 1-7> <dom> <flags_dir> <generations true|false> <max_attempts>
# Prints the due archive tiers, highest first, one per line; nothing means an
# hourly backup. A tier is due for the whole calendar day until its flag
# <tier>_<date> exists (daily every day, weekly on Sunday, monthly on the first
# Sunday), unless attempts_<tier>_<date> has reached <max_attempts>.
bk_due_tiers() {
  local date="$1" dow="$2" dom="$3" flags="$4" generations="$5" max="${6:-3}"
  [[ "$generations" == "true" ]] || return 0
  dom=$((10#$dom))
  local tier
  for tier in monthly weekly daily; do
    case "$tier" in
      monthly) [[ "$dow" -eq 7 && "$dom" -le 7 ]] || continue ;;
      weekly) [[ "$dow" -eq 7 ]] || continue ;;
    esac
    [[ -e "$flags/${tier}_${date}" ]] && continue
    if [[ -f "$flags/attempts_${tier}_${date}" ]]; then
      local n
      n="$(cat "$flags/attempts_${tier}_${date}" 2>/dev/null || echo 0)"
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= max )) && continue
    fi
    echo "$tier"
  done
  return 0
}
