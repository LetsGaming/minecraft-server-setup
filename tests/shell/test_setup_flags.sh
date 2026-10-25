#!/bin/bash
# Setup flag prompting (API wrapper), the package installer's tool list and the
# tools --check verifies. Nothing installs anything: sudo and npm are shims and
# the prompt is a stub.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  export SCRIPT_DIR="$T"
  command -v cygpath > /dev/null 2>&1 && SCRIPT_DIR="$(cygpath -m "$T")"
  mkdir -p "$T/bin"
}

write_variables() { # enabled (true|false)
  printf '{ "API_SERVER": { "ENABLED": %s } }\n' "$1" > "$T/variables.json"
}

# Prints "flag=<value> asked=<n>" after prompt_for_flags with every other
# prompt already answered.
prompt_result() { # initial SETUP_API_SERVER
  (
    ask_yes_no() { echo "$1" >> "$T/asked"; return 1; }
    source "$REPO/src/common/flags.sh"
    ACCEPT_ALL=false NO_START=true EULA=true NO_SERVICE=true NO_BACKUP=true SETUP_API_SERVER="$1"
    prompt_for_flags
    echo "flag=$SETUP_API_SERVER asked=$(grep -c . "$T/asked" 2> /dev/null || echo 0)"
  )
}

test_enabled_in_config_skips_the_wrapper_prompt() {
  setup; write_variables true
  assert_eq "flag=true asked=0" "$(prompt_result false)" "wrapper is set up and nothing is asked"
}

test_disabled_in_config_still_asks() {
  setup; write_variables false
  assert_eq "flag=false asked=1" "$(prompt_result false)" "the answer decides"
}

test_the_flag_still_works_when_disabled_in_config() {
  setup; write_variables false
  assert_eq "flag=true asked=0" "$(prompt_result true)" "--api-server is kept and not asked again"
}

# Which setup and cleanup function a run picks for MODPACK.
dispatch_result() { # MODPACK value
  (
    run_modpack_setup() { echo -n "modpack-setup "; }
    run_vanilla_setup() { echo -n "vanilla-setup "; }
    run_modpack_cleanup() { echo -n "modpack-cleanup "; }
    run_vanilla_cleanup() { echo -n "vanilla-cleanup "; }
    source <(sed -n '/^run_server_setup()/,/^}/p;/^run_server_cleanup()/,/^}/p' "$REPO/src/common/setup.sh")
    MODPACK="$1"
    run_server_setup; run_server_cleanup
  )
}

test_a_default_run_uses_the_vanilla_setup_and_cleanup() {
  assert_eq "vanilla-setup vanilla-cleanup " "$(dispatch_result false)" "default is vanilla/Fabric"
}

test_the_modpack_flag_switches_setup_and_cleanup() {
  assert_eq "modpack-setup modpack-cleanup " "$(dispatch_result true)" "--modpack picks the modpack pair"
}

test_an_unset_modpack_variable_means_vanilla() {
  assert_eq "vanilla-setup vanilla-cleanup " "$(dispatch_result "")" "unset MODPACK falls back to vanilla"
}

test_main_declares_the_modpack_flag_and_drops_the_vanilla_flag() {
  assert_contains "$(grep -- '"--modpack"' "$REPO/main.sh")" "MODPACK=false" "flag is declared with a false default"
  assert_eq "" "$(grep -- '"--vanilla"' "$REPO/main.sh" || true)" "--vanilla is no longer declared"
  assert_missing "$REPO/main-vanilla.sh" "main-vanilla.sh is removed"
}

test_install_script_installs_every_prerequisite() {
  setup
  export SHIM_LOG="$T/shim.log"; : > "$SHIM_LOG"
  printf '#!/bin/bash\necho "sudo $*" >> "$SHIM_LOG"\nexit 0\n' > "$T/bin/sudo"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/npm"
  printf '#!/bin/bash\nprintf "nodejs:\\n  Candidate: 20.1.0\\n"\n' > "$T/bin/apt-cache"
  chmod +x "$T/bin/sudo" "$T/bin/npm" "$T/bin/apt-cache"
  # PATH holds only the shims, so every tool except npm counts as missing.
  PATH="$T/bin" "$BASH" "$REPO/src/setup/download/download_packages.sh" > /dev/null 2>&1
  local cmd pkg
  source "$REPO/src/common/prereqs.sh"
  for cmd in "${!PREREQ_COMMANDS[@]}"; do
    pkg="${PREREQ_COMMANDS[$cmd]}"
    [[ "$pkg" == nodejs || "$pkg" == npm ]] && continue
    assert_logged "sudo apt install -y $pkg" "$pkg is installed"
  done
  assert_logged "sudo apt install -y nodejs npm" "node is installed from the distribution"
}

test_ask_yes_no_is_unchanged_for_the_power_user_route() {
  local out
  out="$( ( source "$REPO/src/common/prompts.sh"; ask_yes_no "Q?" && echo YES || echo NO ) <<< "" 2>&1 )"
  assert_contains "$out" "YES" "an empty answer is yes"
  out="$( ( source "$REPO/src/common/prompts.sh"; ask_yes_no "Q?" && echo YES || echo NO ) < /dev/null 2>&1 )"
  assert_contains "$out" "YES" "end of input in an && list is yes, as before"
  out="$( ( source "$REPO/src/common/prompts.sh"; source "$REPO/src/common/flags.sh"
    api_server_enabled_in_config() { return 0; }
    NO_START=false EULA=false NO_SERVICE=false NO_BACKUP=false SETUP_API_SERVER=false ACCEPT_ALL=false
    prompt_for_flags
    echo "service=$NO_SERVICE backup=$NO_BACKUP eula=$EULA" ) < /dev/null 2>&1 )"
  assert_contains "$out" "service=false backup=false eula=true" "prompt_for_flags at end of input is unchanged"
}

test_preflight_reports_each_required_tool() {
  setup; write_variables false
  local out
  out="$( ( source "$REPO/src/common/setup.sh"; run_preflight_check ) 2>&1 < /dev/null || true )"
  local tool
  for tool in screen rsync zstd tar curl jq unzip cron setfacl; do
    if [[ "$out" == *"✓ $tool"* || "$out" == *"✗ $tool not found"* ]]; then
      _ok "--check looks at $tool"
    else
      _bad "--check looks at $tool" "no result line for $tool"
    fi
  done
}

run_tests
