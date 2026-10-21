#!/bin/bash
# Prerequisite stage. PATH holds only a temp shim dir, so a tool counts as present
# exactly when it has a shim there. Every shim logs its call to $SHIM_LOG.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

REAL_MKTEMP="$(command -v mktemp)"
REAL_RM="$(command -v rm)"

# new_env <present tools...>: fresh bin dir with logging shims for the given tools.
new_env() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  BIN="$T/bin"; mkdir -p "$BIN"
  export SHIM_LOG="$T/shim.log"; : > "$SHIM_LOG"
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$REAL_MKTEMP" > "$BIN/mktemp"
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$REAL_RM" > "$BIN/rm"
  local tool
  for tool in "$@"; do
    printf '#!/bin/bash\necho "%s $*" >> "$SHIM_LOG"\nexit 0\n' "$tool" > "$BIN/$tool"
  done
  chmod +x "$BIN"/*
}

shim_node() { # version e.g. v20.1.0
  printf '#!/bin/bash\nif [ "$1" = -v ]; then echo %s; else echo "node $*" >> "$SHIM_LOG"; fi\n' "$1" > "$BIN/node"
  chmod +x "$BIN/node"
}

shim_candidate() { # candidate version string
  printf '#!/bin/bash\necho "apt-cache $*" >> "$SHIM_LOG"\nprintf "nodejs:\n  Installed: (none)\n  Candidate: %s\n"\n' "$1" > "$BIN/apt-cache"
  chmod +x "$BIN/apt-cache"
}

# Runs <function> [args] with the shim PATH; prints output, exit code on the last line.
in_env() {
  local out rc=0
  out="$( ( PATH="$BIN" ; source "$REPO/src/common/prereqs.sh"; "$@" ) 2>&1 )" || rc=$?
  echo "$out"
  echo "rc=$rc"
}


test_installs_only_missing_packages() {
  new_env apt sudo systemctl screen unzip cron jq rsync zstd setfacl node npm
  shim_node v20.1.0
  in_env ensure_prerequisites power > /dev/null
  assert_logged "sudo apt install -y curl" "curl is installed"
  assert_not_logged "apt install -y jq" "jq is left alone"
  assert_not_logged "apt install -y screen" "screen is left alone"
  assert_not_logged "apt install -y nodejs" "node is left alone"
}

test_whiptail_only_for_guided() {
  new_env curl screen unzip cron jq rsync zstd setfacl node npm
  assert_eq "" "$(in_env prereqs_missing default | grep -v '^rc=')" "default needs no whiptail"
  assert_eq "" "$(in_env prereqs_missing power | grep -v '^rc=')" "power needs no whiptail"
  assert_eq "whiptail" "$(in_env prereqs_missing guided | grep -v '^rc=')" "guided adds whiptail"
}

test_node_ok_when_18_or_newer() {
  new_env
  shim_node v18.0.0
  assert_eq "ok" "$(in_env node_install_action | head -n 1)" "18 is accepted"
  shim_node v22.3.1
  assert_eq "ok" "$(in_env node_install_action | head -n 1)" "22 is accepted"
  shim_node v16.20.0
  shim_candidate 20.1.0
  assert_eq "distro" "$(in_env node_install_action | head -n 1)" "16 is too old"
}

test_node_action_distro_when_candidate_18() {
  new_env
  shim_candidate "18.19.0+dfsg-6~deb12u2"
  assert_eq "distro" "$(in_env node_install_action | head -n 1)" "distro 18"
  shim_candidate "2:20.11.0-1"
  assert_eq "distro" "$(in_env node_install_action | head -n 1)" "epoch is stripped"
}

test_node_action_nodesource_when_candidate_12() {
  new_env
  shim_candidate "12.22.9~dfsg-1ubuntu3.6"
  assert_eq "nodesource" "$(in_env node_install_action | head -n 1)" "candidate 12"
  shim_candidate "(none)"
  assert_eq "nodesource" "$(in_env node_install_action | head -n 1)" "no candidate"
}

test_nodesource_refused_without_flag() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl npm
  shim_candidate 12.22.9
  local out
  out="$(in_env ensure_prerequisites power)"
  assert_contains "$out" "rc=1" "exits 1"
  assert_contains "$out" "https://deb.nodesource.com/setup_22.x" "shows the setup command"
  assert_contains "$out" "sudo -E bash" "shows how it is run"
  assert_contains "$out" "--allow-nodesource" "shows the flag"
  assert_not_logged "apt install" "nothing is installed"
  assert_not_logged "curl " "nothing is downloaded"
}

test_nodesource_allowed_with_flag() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl npm
  shim_candidate 12.22.9
  local out
  out="$(ALLOW_NODESOURCE=true in_env ensure_prerequisites power)"
  assert_contains "$out" "rc=0" "succeeds"
  assert_logged "curl -fsSL https://deb.nodesource.com/setup_22.x -o " "setup script is downloaded"
  assert_logged "sudo -E bash " "setup script is run"
  assert_logged "sudo apt install -y nodejs" "nodejs is installed"
}

test_no_system_upgrade_by_default() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl node npm
  shim_node v20.1.0
  in_env ensure_prerequisites power > /dev/null
  assert_logged "sudo apt update" "package list is refreshed"
  assert_not_logged "apt upgrade" "no upgrade"
  MC_SETUP_UPGRADE_SYSTEM=true in_env ensure_prerequisites power > /dev/null
  assert_logged "sudo apt upgrade -y" "opt-in upgrades"
}

test_dry_run_installs_nothing() {
  new_env sudo systemctl screen unzip cron jq rsync zstd setfacl node npm
  shim_node v20.1.0
  local out
  out="$(DRY_RUN=true in_env ensure_prerequisites power)"
  assert_contains "$out" "[DRY-RUN] sudo apt install -y curl" "install is announced"
  assert_not_logged "apt install" "apt is not called"
  assert_not_logged "npm ci" "npm ci is not run"
}

test_second_call_is_a_no_op() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl node npm
  shim_node v20.1.0
  local out
  out="$( ( PATH="$BIN"; source "$REPO/src/common/prereqs.sh"; ensure_prerequisites power > /dev/null; : > "$SHIM_LOG"; ensure_prerequisites power ) 2>&1 )"
  assert_eq "" "$out" "second call prints nothing"
  assert_eq "0" "$(wc -c < "$SHIM_LOG" | tr -d ' ')" "second call runs nothing"
}

test_node_action_is_decided_after_apt_update() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl npm
  cat > "$BIN/apt-cache" << 'SHIM'
#!/bin/bash
updated=false
while IFS= read -r line; do
  [[ "$line" == "sudo apt update"* ]] && updated=true
done < "$SHIM_LOG"
if [ "$updated" = true ]; then
  printf 'nodejs:\n  Candidate: 18.19.0\n'
else
  printf 'nodejs:\n  Candidate: (none)\n'
fi
SHIM
  chmod +x "$BIN/apt-cache"
  local out
  out="$(in_env ensure_prerequisites power)"
  assert_contains "$out" "rc=0" "no refusal on empty apt lists"
  assert_logged "sudo apt install -y nodejs npm" "distro package is used"
  assert_not_logged "nodesource" "no NodeSource command"
  assert_not_logged "curl " "nothing is downloaded"
}

test_distro_action_installs_nodejs_and_npm() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl
  shim_candidate 20.11.0
  in_env ensure_prerequisites power > /dev/null
  assert_logged "sudo apt install -y nodejs npm" "node and npm come from the distribution"
}

test_npm_ci_runs_in_the_repo_root() {
  new_env apt sudo systemctl curl screen unzip cron jq rsync zstd setfacl node
  shim_node v20.1.0
  mkdir -p "$T/root"
  printf '#!/bin/bash\necho "npm $* in $PWD" >> "$SHIM_LOG"\n' > "$BIN/npm"
  chmod +x "$BIN/npm"
  local root; root="$(cd "$T/root" && pwd)"
  SCRIPT_DIR="$root" in_env ensure_prerequisites power > /dev/null
  assert_logged "npm ci --omit=dev in $root" "npm ci runs from SCRIPT_DIR"
}

test_failed_nodesource_download_leaves_no_temp_script() {
  new_env apt sudo systemctl screen unzip cron jq rsync zstd setfacl npm
  shim_candidate 12.22.9
  printf '#!/bin/bash\necho "curl $*" >> "$SHIM_LOG"\n: > "${@: -1}"\nexit 22\n' > "$BIN/curl"
  chmod +x "$BIN/curl"
  local out script
  out="$(ALLOW_NODESOURCE=true in_env ensure_prerequisites power)"
  assert_not_contains "$out" "rc=0" "the failure is reported"
  script="$(sed -n 's/^curl .* -o //p' "$SHIM_LOG" | head -n 1)"
  assert_eq "1" "$([ -n "$script" ] && echo 1)" "the download was attempted"
  assert_missing "$script" "temp script is removed"
  assert_not_logged "sudo -E bash" "the script is not run"
}

run_tests
