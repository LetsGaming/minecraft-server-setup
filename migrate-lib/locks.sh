#!/bin/bash
# The operation lock: refuse to migrate while an upgrade, restore, rollback or mod change runs.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# The scripts are swapped under a running server, so nothing may be running
# from them meanwhile: an upgrade or prune job, a restore, a rollback, a mod
# change. They all take this lock; take it too, and stop before changing
# anything when one of them holds it. The scripts take it in INSTANCE_LOCK_DIR,
# else .locks; scripts from before that folder was fixed may hold theirs under
# $XDG_RUNTIME_DIR/minecraft, so that is checked as well.
acquire_migration_locks() {
  local dirs=() dir lock fd
  [[ -n "${INSTANCE_LOCK_DIR:-}" ]] && dirs+=("$INSTANCE_LOCK_DIR")
  [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR/minecraft" ]] && dirs+=("$XDG_RUNTIME_DIR/minecraft")
  dirs+=("$TARGET_SCRIPTS_DIR/.locks")
  command -v flock &>/dev/null || { warn "flock not found — cannot check for a running operation"; return 0; }
  for dir in "${dirs[@]}"; do
    ( umask 077; mkdir -p "$dir" ) || continue
    lock="$dir/operation_${INSTANCE_NAME}.lock"
    exec {fd}> "$lock" || continue
    if ! flock -n "$fd"; then
      err "Another operation ($(cat "$lock.kind" 2>/dev/null || echo unknown)) is running for '$INSTANCE_NAME'."
      info "Run the migration again once it has finished. Nothing was changed."
      exit 1
    fi
  done
}
