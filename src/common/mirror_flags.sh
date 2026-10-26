#!/bin/bash
set -e

# --mirror-target on the Default or Guided route has no variables.json to read
# the survival host and seed from, so they come from --mirror-remote and
# --mirror-seed (asked for on a terminal when missing) and are written into
# variables.json for run_mirror_setup.

_mirror_ask() { # prompt
  local answer
  read -r -p "$1" answer || answer=""
  printf '%s' "$answer"
}

# Called after the route is chosen and before anything is changed.
mirror_flags_check() {
  if [[ "${MIRROR_TARGET:-false}" != true ]]; then
    if [[ -n "${MIRROR_REMOTE:-}" || -n "${MIRROR_SEED:-}" ]]; then
      ui_notice error "--mirror-remote and --mirror-seed only make sense together with --mirror-target." >&2
      exit 1
    fi
    return 0
  fi
  [[ "${MIRROR_SOURCE:-false}" == true ]] && {
    ui_notice error "--mirror-source and --mirror-target cannot be used together." >&2
    exit 1
  }
  # The Power-user route reads these from variables.json; flags only override them.
  [[ "$ROUTE" == power ]] && return 0

  if [[ -z "${MIRROR_REMOTE:-}" ]] && ui_is_interactive; then
    MIRROR_REMOTE="$(_mirror_ask "Address of the survival server (host or IP): ")"
  fi
  if [[ -z "${MIRROR_SEED:-}" ]] && ui_is_interactive; then
    MIRROR_SEED="$(_mirror_ask "Seed of the survival world (level-seed in its server.properties): ")"
  fi
  if [[ -z "${MIRROR_REMOTE:-}" || -z "${MIRROR_SEED:-}" ]]; then
    ui_notice error "--mirror-target needs the survival server and its world seed: add --mirror-remote=<host-or-ip> --mirror-seed=<level-seed>. Nothing was changed." >&2
    exit 1
  fi
  local host="${MIRROR_REMOTE#mcsync@}"
  if [[ ! "$host" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    ui_notice error "--mirror-remote must be a host name or address (optionally mcsync@host). Nothing was changed." >&2
    exit 1
  fi
  if [[ ! "$MIRROR_SEED" =~ ^-?[A-Za-z0-9_.-]{1,64}$ ]]; then
    ui_notice error "--mirror-seed may only contain letters, digits, - _ . Nothing was changed." >&2
    exit 1
  fi
}

# Called once variables.json exists (after the wizard, or for the Power-user route).
mirror_flags_apply() {
  [[ "${MIRROR_TARGET:-false}" == true ]] || return 0
  # On the Power-user route the file already holds the settings; only flags override them.
  [[ "$ROUTE" != power || -n "${MIRROR_REMOTE:-}" || -n "${MIRROR_SEED:-}" ]] || return 0
  local -a args=("$SCRIPT_DIR/src/setup/management/apply_mirror_flags.js" "$SCRIPT_DIR/variables.json")
  [[ -z "${MIRROR_REMOTE:-}" ]] || args+=(--remote "$MIRROR_REMOTE")
  [[ -z "${MIRROR_SEED:-}" ]] || args+=(--seed "$MIRROR_SEED")
  if [[ "${DRY_RUN:-false}" == true ]]; then
    echo "[dry-run] would write the mirror target settings into variables.json"
    return 0
  fi
  node "${args[@]}"
}
