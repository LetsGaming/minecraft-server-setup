#!/bin/bash
# Wizard validators. ss is a function stub so port checks do not depend on the host.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
}

# Prints "<message>|rc=<n>" for one validator call.
check() { # validator, args...
  local out rc=0
  out="$(
    source "$REPO/src/common/detect.sh"
    source "$REPO/src/wizard/validators.sh"
    ss() { printf 'LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:*\n'; }
    "$@"
  )" || rc=$?
  echo "$out|rc=$rc"
}

# Prints the output of run_validators followed by "rc=<n>".
run_list() { # value, validator specs...
  REPO="$REPO" bash -c 'source "$REPO/src/common/detect.sh"; source "$REPO/src/wizard/validators.sh"; rc=0; run_validators "$@" || rc=$?; echo "rc=$rc"' _ "$@"
}

test_port() {
  assert_eq "|rc=0" "$(check validate_port 25565)" "valid port"
  assert_contains "$(check validate_port 70000)" "must be a number from 1 to 65535" "too large"
  assert_contains "$(check validate_port 70000)" "rc=1" "too large fails"
  assert_contains "$(check validate_port 0)" "rc=1" "zero fails"
  assert_contains "$(check validate_port abc)" "rc=1" "text fails"
}

test_memory_size() {
  assert_eq "|rc=0" "$(check validate_memory_size 4G)" "4G"
  assert_eq "|rc=0" "$(check validate_memory_size 512M)" "512M"
  assert_contains "$(check validate_memory_size 4g)" "like 4G" "lowercase suggests 4G"
  assert_contains "$(check validate_memory_size 4g)" "rc=1" "lowercase fails"
  assert_contains "$(check validate_memory_size 256M)" "at least 512M" "too small"
  assert_contains "$(check validate_memory_size 0G)" "rc=1" "zero fails"
  assert_contains "$(check validate_memory_size 4)" "rc=1" "no unit fails"
}

test_int_range() {
  assert_eq "|rc=0" "$(check validate_int_range 5 1 10)" "inside"
  assert_contains "$(check validate_int_range 11 1 10)" "from 1 to 10" "above"
  assert_contains "$(check validate_int_range 11 1 10)" "rc=1" "above fails"
  assert_contains "$(check validate_int_range x 1 10)" "rc=1" "text fails"
}

test_instance_name() {
  assert_eq "|rc=0" "$(check validate_instance_name my-server_1)" "valid name"
  assert_contains "$(check validate_instance_name "my server")" "letters, numbers" "space explained"
  assert_contains "$(check validate_instance_name "my server")" "rc=1" "space fails"
  assert_contains "$(check validate_instance_name "")" "rc=1" "empty fails"
}

test_free_port() {
  assert_eq "|rc=0" "$(check validate_free_port 25570)" "free port"
  assert_contains "$(check validate_free_port 25565)" "already in use" "busy port"
  assert_contains "$(check validate_free_port 25565)" "rc=1" "busy port fails"
  assert_contains "$(check validate_free_port 99999)" "1 to 65535" "invalid port fails first"
}

test_min_disk_gb() {
  setup
  assert_eq "|rc=0" "$(check validate_min_disk_gb "$T" 0)" "enough"
  assert_contains "$(check validate_min_disk_gb "$T" 99999999)" "GB free" "not enough"
  assert_contains "$(check validate_min_disk_gb "$T" 99999999)" "rc=1" "not enough fails"
}

test_nonempty() {
  assert_eq "|rc=0" "$(check validate_nonempty x)" "text"
  assert_contains "$(check validate_nonempty "")" "rc=1" "empty fails"
  assert_contains "$(check validate_nonempty "   ")" "rc=1" "blank fails"
}

test_one_of() {
  assert_eq "|rc=0" "$(check validate_one_of easy peaceful easy hard)" "member"
  assert_contains "$(check validate_one_of x peaceful easy)" "peaceful, easy" "lists choices"
  assert_contains "$(check validate_one_of x peaceful easy)" "rc=1" "non-member fails"
}

test_webhook_url() {
  assert_eq "|rc=0" "$(check validate_webhook_url "")" "empty allowed"
  assert_eq "|rc=0" "$(check validate_webhook_url https://example.com/hook)" "https"
  assert_contains "$(check validate_webhook_url http://example.com)" "https://" "http rejected"
  assert_contains "$(check validate_webhook_url http://example.com)" "rc=1" "http fails"
}

test_curseforge_pack_id() {
  assert_eq "|rc=0" "$(check validate_curseforge_pack_id 123456)" "id"
  assert_contains "$(check validate_curseforge_pack_id 0)" "rc=1" "zero fails"
  assert_contains "$(check validate_curseforge_pack_id abc)" "positive whole number" "text explained"
  assert_contains "$(check validate_curseforge_pack_id -5)" "rc=1" "negative fails"
}

test_run_validators() {
  assert_eq "rc=0" "$(run_list 4G validate_nonempty validate_memory_size)" "all pass"
  local expected
  expected="$(check validate_memory_size 256M)"
  assert_eq "${expected%|rc=1}"$'\n'"rc=1" "$(run_list 256M validate_nonempty validate_memory_size validate_port)" "first failure only"
  assert_eq "rc=0" "$(run_list 5 validate_int_range:1:10)" "args after colons"
  assert_contains "$(run_list 11 validate_int_range:1:10)" "from 1 to 10" "args reach the validator"
}

test_validators_are_safe_under_set_e() {
  local out
  out="$(bash -c 'set -e; source "$1/src/common/detect.sh"; source "$1/src/wizard/validators.sh"; if validate_port 0 > /dev/null; then :; fi; echo survived' _ "$REPO")"
  assert_eq "survived" "$out" "caller keeps running"
}

test_validators_match_load_variables() {
  if ! command -v node > /dev/null 2>&1; then skip "validators match loadVariables.js" "node is missing"; return 0; fi
  setup
  mkdir -p "$T/src/setup/common"
  cp "$REPO/src/setup/common/loadVariables.js" "$T/src/setup/common/"
  local name js_ok sh_ok mismatches="" example="$REPO/variables.example.json" out="$T/variables.json" loader="$T/src/setup/common/loadVariables.js"
  if command -v cygpath > /dev/null 2>&1; then
    example="$(cygpath -m "$example")"; out="$(cygpath -m "$out")"; loader="$(cygpath -m "$loader")"
  fi
  for name in server my-server_1 "my server" "bad.name" "" "../x" "a/b" "ok_123" "-" 'x$'; do
    node -e '
      const fs = require("fs");
      const data = JSON.parse(fs.readFileSync(process.argv[1], "utf-8"));
      data.INSTANCE_NAME = process.argv[3];
      fs.writeFileSync(process.argv[2], JSON.stringify(data));
    ' "$example" "$out" "$name"
    js_ok=no
    node -e '
      try { require(process.argv[1])(); }
      catch (e) { if (/INSTANCE_NAME/.test(e.message)) process.exit(1); }
    ' "$loader" > /dev/null 2>&1 && js_ok=yes
    sh_ok=no
    [[ "$(check validate_instance_name "$name")" == "|rc=0" ]] && sh_ok=yes
    [[ "$js_ok" == "$sh_ok" ]] || mismatches="$mismatches [$name js=$js_ok sh=$sh_ok]"
  done
  assert_eq "" "$mismatches" "bash and node agree on every instance name"
}

run_tests
