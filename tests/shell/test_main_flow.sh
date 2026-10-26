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
  local tool
  for tool in curl screen unzip cron jq rsync zstd setfacl ss npm; do
    printf '#!/bin/bash
exit 0
' > "$T/bin/$tool"
  done
  printf '#!/bin/bash
printf "nodejs:\n  Candidate: 12.22.9\n"
' > "$T/bin/apt-cache"
  printf '#!/bin/bash
exit 127
' > "$T/bin/node"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/apt-get"
  chmod +x "$T/bin"/*
  mkdir -p "$T/systemd"
  printf 'ID=ubuntu\nID_LIKE=debian\n' > "$T/os-release"
  export MC_SETUP_SYSTEMD_DIR="$T/systemd" MC_SETUP_OS_RELEASE="$T/os-release"
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
  out="$(run_main --default --guided --allow-nodesource --help)"
  assert_contains "$out" "--allow-nodesource" "new flags are listed"
  assert_contains "$out" "--default" "new flags are listed"
  assert_contains "$out" "--guided" "new flags are listed"
  out="$(
    eval "$(sed -n '/^declare -A ARG_OPTS=(/,/^)/p' "$REPO/main.sh")"
    source "$REPO/src/common/args.sh"
    parse_args --default --guided --allow-nodesource --check --dry-run --verbose --no-start --no-service --no-backup --agree-eula --api-server --modpack --y
    echo "$DEFAULT_ROUTE $GUIDED_ROUTE $ALLOW_NODESOURCE $CHECK_ONLY $DRY_RUN $VERBOSE $NO_START $NO_SERVICE $NO_BACKUP $EULA $SETUP_API_SERVER $MODPACK $ACCEPT_ALL"
  )"
  assert_eq "true true true true true true true true true true true true true" "$out" "every flag sets its variable"
}

test_guided_route_reaches_the_wizard_after_prerequisites() {
  setup
  printf '#!/bin/bash
[ "$1" = -v ] && { echo v20.1.0; exit 0; }
exit 1
' > "$T/bin/node"; chmod +x "$T/bin/node"
  local out
  out="$(MC_SETUP_FORCE_TTY=1 run_main --guided --dry-run)"
  assert_contains "$out" "check your internet connection" "wizard runs and stops before any change"
  assert_contains "$out" "rc=1" "exits 1"
  assert_missing "$T/repo/variables.json" "no config written"
}

# Prints the output of a main.sh run that must stop at the platform check.
assert_platform_refused() { # label
  local out
  out="$(run_main --default --agree-eula)"
  assert_contains "$out" "rc=1" "$1: exits 1"
  assert_contains "$out" "supports Debian and Ubuntu with systemd" "$1: says what is supported"
  assert_contains "$out" "Nothing was changed" "$1: says nothing changed"
  assert_not_logged "apt" "$1: nothing is installed"
  assert_missing "$T/repo/variables.json" "$1: nothing written"
  PLATFORM_OUT="$out"
}

test_platform_without_apt_is_refused() {
  setup
  if PATH="/usr/bin:/bin" command -v apt-get > /dev/null 2>&1; then
    skip "missing apt-get" "this host has a real apt-get on the base PATH"
    return 0
  fi
  rm -f "$T/bin/apt-get"
  assert_platform_refused "no apt"
  assert_contains "$PLATFORM_OUT" "apt-get" "names the missing package manager"
}

test_platform_without_systemd_is_refused() {
  setup
  export MC_SETUP_SYSTEMD_DIR="$T/no-systemd"
  assert_platform_refused "no systemd"
  assert_contains "$PLATFORM_OUT" "systemd" "names systemd"
}

test_platform_non_debian_is_refused() {
  setup
  printf 'ID=fedora
ID_LIKE="rhel centos"
' > "$T/os-release"
  assert_platform_refused "fedora"
  assert_contains "$PLATFORM_OUT" "Debian-family" "names the missing OS family"
}

test_platform_debian_derivative_is_accepted() {
  setup
  printf 'ID=linuxmint
ID_LIKE="ubuntu debian"
' > "$T/os-release"
  local out
  out="$(run_main --default --agree-eula)"
  assert_not_contains "$out" "supports Debian and Ubuntu" "derivative passes the platform check"
}

run_tests
