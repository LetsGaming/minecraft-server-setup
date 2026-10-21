#!/bin/bash
# main.sh stage order. PATH is a temp shim dir plus /usr/bin, so node counts as present only when shimmed.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/repo" "$T/bin" "$T/home"
  cp "$REPO/main.sh" "$REPO/variables.example.json" "$T/repo/"
  cp -r "$REPO/src" "$T/repo/src"
  export SHIM_LOG="$T/shim.log"; : > "$SHIM_LOG"
  printf '#!/bin/bash\n[ "$1" = -v ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
  printf '#!/bin/bash\necho "apt $*" >> "$SHIM_LOG"\n[ "$1" = update ] && exit 0\nexit 100\n' > "$T/bin/apt"
  chmod +x "$T/bin"/*
}

run_main() { # args...; prints output then rc=<n>
  local out rc=0
  out="$(cd "$T/repo" && HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" bash main.sh "$@" < /dev/null 2>&1)" || rc=$?
  echo "$out"
  echo "rc=$rc"
}

test_no_node_on_path_gives_clear_message() {
  setup; cp "$T/repo/variables.example.json" "$T/repo/variables.json"
  local out
  out="$(run_main)"
  assert_contains "$out" "Node" "names Node"
  assert_not_contains "$out" "variables.json is missing or invalid" "does not blame the config"
  assert_contains "$out" "rc=1" "stops"
}

test_power_route_missing_config_still_creates_and_exits() {
  setup
  local out
  out="$(run_main)"
  assert_contains "$out" "rc=1" "exits 1"
  assert_exists "$T/repo/variables.json" "created from the example"
  assert_not_logged "apt" "nothing is installed first"
}

test_existing_flags_still_parse() {
  setup
  local out
  out="$(run_main --dry-run --no-start --agree-eula --no-service --no-backup --api-server --verbose --y --vanilla)"
  assert_not_contains "$out" "Unknown option" "all existing flags are accepted"
  out="$(run_main --default --guided --allow-nodesource --help)"
  assert_contains "$out" "--allow-nodesource" "new flags are listed"
  assert_contains "$out" "--default" "new flags are listed"
  assert_contains "$out" "--guided" "new flags are listed"
}

test_guided_route_installs_then_stops_at_the_wizard_stub() {
  setup
  printf '#!/bin/bash
[ "$1" = -v ] && echo v20.1.0
exit 0
' > "$T/bin/node"; chmod +x "$T/bin/node"
  local out
  out="$(run_main --guided --dry-run)"
  assert_contains "$out" "not available yet" "wizard stub speaks"
  assert_contains "$out" "rc=1" "exits 1"
}

run_tests
