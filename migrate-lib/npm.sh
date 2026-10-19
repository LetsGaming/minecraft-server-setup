#!/bin/bash
# npm helpers and the per-instance dependency install step.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# True when the deployed dependency set differs from the source one. Checks the
# lockfile too — a package.json-only comparison misses a lockfile bump and
# leaves node_modules out of sync with what the suite ships.
_pkg_deps_changed() {
  local src_dir="$1" dst_dir="$2"
  [[ -f "$dst_dir/package.json" ]] || return 0
  diff -q "$src_dir/package.json" "$dst_dir/package.json" &>/dev/null || return 0
  if [[ -f "$src_dir/package-lock.json" || -f "$dst_dir/package-lock.json" ]]; then
    diff -q "$src_dir/package-lock.json" "$dst_dir/package-lock.json" &>/dev/null || return 0
  fi
  return 1
}

# Install dependencies for a deployed component. Prefers `npm ci` when a
# lockfile is present (reproducible, matches the shipped tree exactly).
# $2 = "dev" includes devDependencies.
_npm_install() {
  local dir="$1" mode="${2:-prod}"
  local omit=()
  if [[ "$mode" != dev ]]; then omit=(--omit=dev); fi
  if [[ -f "$dir/package-lock.json" ]]; then
    run_cmd npm ci "${omit[@]}" --prefix "$dir"
  else
    run_cmd npm install "${omit[@]}" --prefix "$dir"
  fi
}

# Step 7.
install_instance_npm_deps() {
  if $NEEDS_ANY_NPM_INSTALL; then
    echo; echo -e "${BOLD}Step 7: Install npm dependencies${NC}"
    if command -v npm &>/dev/null; then
      for entry in "${NPM_SUBDIRS[@]}"; do
        subdir="${entry%%:*}"; needs_install="${entry##*:}"
        [[ "$needs_install" != true ]] && continue
        dir="$TARGET_SCRIPTS_DIR/$subdir"
        [[ -f "$dir/package.json" ]] || continue
        log "npm install --omit=dev in ${subdir}/"
        _npm_install "$dir"
      done
      log "Dependencies installed"
    else
      warn "npm not found — run manually:"
      for entry in "${NPM_SUBDIRS[@]}"; do
        subdir="${entry%%:*}"; needs_install="${entry##*:}"
        [[ "$needs_install" == true ]] && info "  npm install --omit=dev --prefix '$TARGET_SCRIPTS_DIR/$subdir'"
      done
    fi
  fi
  return 0
}
