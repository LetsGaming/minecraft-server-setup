#!/bin/bash
# Tests for src/setup/management/service_user.sh. Nothing here creates a user or
# touches an ACL: --print-sudoers and --dry-run only print, and the unit patch is
# pointed at a scratch directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

ROOT="$(cd "$HERE/../.." && pwd)"
SU="$ROOT/src/setup/management/service_user.sh"
TOOLS=(--bash-path /usr/bin/bash --node-path /usr/bin/node --screen-path /usr/bin/screen --systemctl-path /usr/bin/systemctl)

setup() {
  make_fixture; trap cleanup_fixture EXIT
  mkdir -p "$T/server/config" "$T/server/world/stats" "$T/server/world/serverconfig" "$T/server/plugins"
  : > "$T/server/server.properties"
}

test_the_sudoers_rules_name_exact_scripts_and_nothing_broad() {
  setup
  local out
  out="$(bash "$SU" --scripts-dir "$T/scripts" --user mcapi-test "${TOOLS[@]}" --print-sudoers)"
  assert_contains "$out" "mcapi-test ALL=(tester) NOPASSWD:" "scripts run as the server user"
  assert_contains "$out" "/usr/bin/bash $T/scripts/backup/backup.sh," "a script is named exactly"
  assert_contains "$out" "/usr/bin/node $T/scripts/world/prune-chunks.js *," "the prune script with its arguments"
  assert_contains "$out" "/usr/bin/bash $T/scripts/backup/restore.sh --file $T/backups/* --y," "restore only of an archive in the backups folder, confirmed"
  assert_contains "$out" "/usr/bin/bash $T/scripts/backup/backup.sh --archive," "backup with --archive"
  assert_contains "$out" "Cmnd_Alias MCS_TESTINST_UNIT" "alias names are upper case (S-005)"
  assert_contains "$out" "/usr/bin/systemctl restart testinst.service," "the unit's own restart"
  assert_contains "$out" "/usr/bin/screen -S testinst -X stuff *" "console input only for this session"
  assert_not_contains "$out" "ALL=(ALL)" "no grant to run as anyone"
  assert_not_contains "$out" "NOPASSWD: ALL" "no blanket command grant"
  # A wildcard may follow a script as its arguments, never sit in the path.
  assert_eq "" "$(printf '%s\n' "$out" | grep -E '/[^ ,]*\*[^ ,]*\.(sh|js)' || true)" "no wildcard in a script path"
  assert_not_contains "$out" "systemctl enable" "no unit installation"
}

test_the_generated_rules_parse() {
  setup
  if ! command -v visudo > /dev/null 2>&1; then skip "visudo parses the rules" "visudo is not installed"; return; fi
  bash "$SU" --scripts-dir "$T/scripts" --user mcapi-test "${TOOLS[@]}" --print-sudoers > "$T/rules"
  visudo -cf "$T/rules" > /dev/null && _ok "visudo accepts the rules" || _bad "visudo accepts the rules"
}

test_a_dry_run_plans_the_user_and_the_grants_and_changes_nothing() {
  setup
  local out
  out="$(bash "$SU" --scripts-dir "$T/scripts" --user mcapi-test-zz "${TOOLS[@]}" --dry-run 2>&1)"
  assert_contains "$out" "useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin mcapi-test-zz" "an unprivileged system user"
  assert_contains "$out" "setfacl -R -m u:mcapi-test-zz:rX $T/server" "read on the server folder"
  assert_contains "$out" "setfacl -R -m u:mcapi-test-zz:rwX $T/server/config" "write on a config folder"
  assert_contains "$out" "setfacl -m u:mcapi-test-zz:rwX $T/server/server.properties" "write on server.properties only as a file"
  assert_contains "$out" "setfacl -R -m u:mcapi-test-zz:rwX $T/server/world/stats" "write on the stats folder"
  assert_not_contains "$out" "rwX $T/server/plugins" "never write on plugins/, where jars run as the owner (S-004)"
  assert_contains "$out" "$T/backups -type d -exec setfacl" "write on the backups folders, not their archives"
  assert_not_contains "$out" "rwX $T/server " "never write on the whole server folder"
  assert_not_contains "$out" "rwX $T/server/world " "never write on the world"
  assert_missing "$T/etc-sudoers" "nothing was installed"
}

test_the_service_user_cannot_be_root_or_the_server_user() {
  setup
  local rc=0
  bash "$SU" --scripts-dir "$T/scripts" --user tester "${TOOLS[@]}" --dry-run > /dev/null 2>&1 || rc=$?
  assert_rc 2 "$rc" "the server user is refused"
  rc=0
  bash "$SU" --scripts-dir "$T/scripts" --user root "${TOOLS[@]}" --dry-run > /dev/null 2>&1 || rc=$?
  assert_rc 2 "$rc" "root is refused"
  rc=0
  bash "$SU" --scripts-dir "$T/scripts" --user 'bad name' "${TOOLS[@]}" --dry-run > /dev/null 2>&1 || rc=$?
  assert_rc 2 "$rc" "an invalid name is refused"
}

test_a_path_sudoers_cannot_take_literally_is_refused() {
  setup
  mkdir -p "$T/with space/common"
  cp "$T/scripts/common/variables.txt" "$T/with space/common/"
  local rc=0
  bash "$SU" --scripts-dir "$T/with space" --user mcapi-test "${TOOLS[@]}" --dry-run > /dev/null 2>&1 || rc=$?
  assert_rc 2 "$rc" "a space in the scripts path is refused"
}

test_the_unit_gets_umask_once_and_the_old_unit_is_kept() {
  setup
  mkdir -p "$T/units"
  printf '[Unit]\nDescription=x\n\n[Service]\nUser=tester\nExecStart=/bin/true\n' > "$T/units/testinst.service"
  # shellcheck source=/dev/null
  ( source "$SU"
    SU_UNIT_DIR="$T/units" SU_INSTANCE=testinst SU_DRY_RUN=false
    su_patch_unit > /dev/null
    su_patch_unit > /dev/null )
  assert_eq 1 "$(grep -c '^UMask=0002' "$T/units/testinst.service")" "UMask is added exactly once"
  assert_exists "$T/units/testinst.service.pre-service-user" "the old unit is kept"
  assert_eq "[Service]" "$(grep -B1 '^UMask=' "$T/units/testinst.service" | head -n 1)" "it sits right under [Service]"
}

run_tests
