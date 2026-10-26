#!/bin/bash
# Tests for the mirror's installer side: the managed settings block, the root
# helper (strict validation, the lines it writes), mirror.sh's flows and
# prepare.sh. Privileged steps run in the helper's test mode against a scratch
# /etc; sudo, systemctl and friends are the usual shims.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"
source "$HERE/lib/mirror_fixture.sh"

REAL_NODE="$(command -v node || true)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MIRROR_SH="$REPO_ROOT/mirror.sh"
ROOT_HELPER="$MIRROR_SRC/root_helper.sh"
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderKeyForTestsOnlyAAAAAAAAAAAAAAAAAAAA mc-mirror@tgt"
KEY2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISecondPlaceholderKeyForTestsOnlyAAAAAAAAAAAAAAAA other@host"

setup() {
  make_fixture; trap cleanup_fixture EXIT
  export MC_MIRROR_TEST=1 MC_MIRROR_ETC="$T/etc" SYSTEMD_UNIT_DIR="$T/units" TIMER_SUDO="" SYSTEMD_USABLE=true
  mkdir -p "$T/etc" "$T/units"
  # a stand-in rrsync, where `command -v rrsync` finds it
  { echo '#!/bin/sh'; echo 'exit 0'; } > "$T/bin/rrsync"; chmod +x "$T/bin/rrsync"
}

helper() { OUT="$(bash "$ROOT_HELPER" "$@" 2>&1 < /dev/null)"; RC=$?; }

# ── the managed settings block ───────────────────────────────────────────────

test_the_managed_block_is_added_replaced_and_removed_without_touching_other_lines() {
  setup
  local f="$T/vars.txt"
  printf 'USER="tester"\nRCON_PASSWORD="p"\n' > "$f"
  chmod 600 "$f"
  ( source "$MIRROR_SRC/lib/config.sh"; mirror_config_write "$f" MIRROR_ENABLED=true MIRROR_ROLE=source )
  assert_contains "$(cat "$f")" 'MIRROR_ROLE="source"' "the block is written"
  assert_contains "$(head -n 2 "$f")" 'RCON_PASSWORD="p"' "the suite's lines stay where they were"
  ( source "$MIRROR_SRC/lib/config.sh"; mirror_config_write "$f" MIRROR_ENABLED=true MIRROR_ROLE=target )
  assert_eq 1 "$(grep -c 'MIRROR_ROLE' "$f")" "a second write replaces the block, it does not add another"
  assert_contains "$(cat "$f")" 'MIRROR_ROLE="target"' "with the new value"
  ( source "$MIRROR_SRC/lib/config.sh"; mirror_config_write "$f" )
  assert_not_contains "$(cat "$f")" "MIRROR" "no keys removes the block entirely"
  assert_contains "$(cat "$f")" 'USER="tester"' "and keeps everything else"
  if perms_work_here "$f"; then assert_eq 600 "$(stat -c %a "$f")" "the file keeps its mode"; fi
}

perms_work_here() { : > "$1.p"; chmod 640 "$1.p"; [[ "$(stat -c %a "$1.p")" == 640 ]]; }

test_values_with_shell_metacharacters_are_stored_literally() {
  setup
  local f="$T/vars.txt"
  : > "$f"
  ( source "$MIRROR_SRC/lib/config.sh"; mirror_config_write "$f" 'MIRROR_DIMS=a "b" $HOME `id` \c' )
  local got
  got="$( source "$f"; printf '%s' "$MIRROR_DIMS" )"
  assert_eq 'a "b" $HOME `id` \c' "$got" "nothing in the value is expanded when the file is sourced"
}

test_only_mirror_keys_can_be_written_to_the_block() {
  setup
  : > "$T/vars.txt"
  ( source "$MIRROR_SRC/lib/config.sh"; mirror_config_write "$T/vars.txt" 'USER=evil' ) > /dev/null 2>&1
  assert_nonzero "$?" "a key that is not MIRROR_ is refused"
  assert_not_contains "$(cat "$T/vars.txt")" "evil" "and nothing was written"
}

# ── the root helper ──────────────────────────────────────────────────────────

test_the_helper_refuses_inputs_that_could_inject_into_sshd_or_sudoers() {
  setup
  helper authorize --export-root "/srv/ex port" --from 10.0.0.2 --key "$KEY" --dry-run
  assert_nonzero "$RC" "a path with a space is refused"
  helper authorize --export-root '/srv/export"; rm -rf /' --from 10.0.0.2 --key "$KEY" --dry-run
  assert_nonzero "$RC" "a path with a quote is refused"
  helper authorize --export-root /srv/export --from '10.0.0.2",command="id' --key "$KEY" --dry-run
  assert_nonzero "$RC" "an address that closes the from option is refused"
  helper authorize --export-root /srv/export --from 10.0.0.2 --key "ssh-rsa AAAAB3Nza owner" --dry-run
  assert_nonzero "$RC" "only ed25519 keys are accepted"
  helper authorize --export-root /srv/export --from 10.0.0.2 --key "$KEY
command=\"evil\" $KEY" --dry-run
  assert_nonzero "$RC" "a key spread over two lines is refused"
  helper target-sudoers --user "bob ALL" --instance creative --dry-run
  assert_nonzero "$RC" "a user name with a space is refused"
  helper target-sudoers --user bob --instance 'a;b' --dry-run
  assert_nonzero "$RC" "an instance name with a semicolon is refused"
  helper authorize --export-root /srv/../etc --from 10.0.0.2 --key "$KEY" --dry-run
  assert_nonzero "$RC" "a path with .. is refused"
}

test_authorize_writes_one_pinned_read_only_line_and_replaces_a_known_key() {
  setup
  helper authorize --export-root /srv/export --from 192.168.2.241 --key "$KEY"
  assert_rc 0 "$RC" "authorized"
  local f="$T/etc/ssh/mcsync/authorized_keys" line
  line="$(cat "$f")"
  assert_contains "$line" 'restrict,from="192.168.2.241",command="nice -n 19 ionice -c3 ' "restrict, pinned address, forced command"
  assert_contains "$line" "$T/bin/rrsync -ro /srv/export\" $KEY" "read-only rrsync on the export folder, then the key"
  helper authorize --export-root /srv/export --from 10.9.9.9 --key "$KEY"
  assert_eq 1 "$(grep -c ssh-ed25519 "$f")" "the same key is replaced, not added twice"
  assert_contains "$(cat "$f")" 'from="10.9.9.9"' "with the new address"
  helper authorize --export-root /srv/other --from 10.1.1.1 --key "$KEY2"
  assert_eq 2 "$(grep -c ssh-ed25519 "$f")" "a second key is added next to the first"
}

test_authorize_dry_run_shows_the_line_and_writes_nothing() {
  setup
  helper authorize --export-root /srv/export --from 192.168.2.241 --key "$KEY" --dry-run
  assert_rc 0 "$RC" "dry run"
  assert_contains "$OUT" 'restrict,from="192.168.2.241"' "the line is shown"
  assert_missing "$T/etc/ssh/mcsync/authorized_keys" "nothing was written"
}

test_the_sudoers_rule_names_exactly_start_and_stop_of_one_unit() {
  setup
  helper print-sudoers --user bob --instance creative-1
  assert_rc 0 "$RC" "printed"
  assert_contains "$OUT" "start creative-1.service, " "start is granted"
  assert_contains "$OUT" "stop creative-1.service" "and stop"
  assert_contains "$OUT" "bob ALL=(root) NOPASSWD: MC_MIRROR_CREATIVE_1" "to that user through an upper-case alias"
  assert_not_contains "$OUT" "restart" "nothing else"
  assert_not_contains "$OUT" "*" "no wildcard"
  helper target-sudoers --user bob --instance creative-1
  assert_rc 0 "$RC" "installed"
  assert_exists "$T/etc/sudoers.d/mc-mirror-bob-creative-1" "the rule is in its own file"
  helper target-sudoers --user bob --instance creative-1
  assert_contains "$OUT" "already in place" "a second run changes nothing"
  helper remove-target --user bob --instance creative-1
  assert_missing "$T/etc/sudoers.d/mc-mirror-bob-creative-1" "removal deletes it"
}

test_source_account_dry_run_lists_every_privileged_step() {
  setup
  helper source-account --user tester --export-root "$T/export" --dry-run
  assert_rc 0 "$RC" "dry run"
  assert_contains "$OUT" "useradd --system --create-home --home-dir /var/lib/mcsync --shell /bin/sh mcsync" "a shell account with no password"
  assert_contains "$OUT" "usermod -aG mcsync tester" "the server user joins its group"
  assert_contains "$OUT" "chmod 2750 $T/export" "the export folder is setgid and closed to others"
  assert_contains "$OUT" "Match User mcsync" "the sshd block"
  assert_contains "$OUT" "AllowTcpForwarding no" "without forwarding"
  assert_contains "$OUT" "PermitTTY no" "or a terminal"
}

test_removing_the_last_export_removes_the_account_and_a_shared_one_stays() {
  setup
  helper authorize --export-root /srv/a --from 10.0.0.1 --key "$KEY"
  helper authorize --export-root /srv/b --from 10.0.0.2 --key "$KEY2"
  helper remove-source --export-root /srv/a
  assert_contains "$OUT" "other exports still use" "the account stays while another export needs it"
  assert_eq 1 "$(grep -c ssh-ed25519 "$T/etc/ssh/mcsync/authorized_keys")" "only the other key is left"
  helper remove-source --export-root /srv/b
  assert_contains "$OUT" "no key is left" "the account goes with the last key"
}

# ── mirror.sh ────────────────────────────────────────────────────────────────

mirror_run() { OUT="$(cd "$T" && bash "$MIRROR_SH" "$@" 2>&1 < /dev/null)"; RC=$?; }

inst() { # name role -> an instance whose settings are NOT yet in variables.txt
  mk_instance "$1" "$2"
  sed -i '/^MIRROR_/d' "$T/$1/scripts/common/variables.txt"
  sed -i "s|^USER=.*|USER=\"$(id -un)\"|" "$T/$1/scripts/common/variables.txt"
}

test_help_and_bad_usage() {
  setup
  mirror_run help
  assert_rc 0 "$RC" "help works"
  assert_contains "$OUT" "setup source|target" "and lists setup"
  mirror_run setup sideways --scripts-dir "$T/scripts"
  assert_nonzero "$RC" "an unknown role is refused"
  mirror_run frobnicate
  assert_nonzero "$RC" "an unknown command is refused"
  mirror_run status
  assert_nonzero "$RC" "a command without an instance is refused"
  assert_contains "$OUT" "--scripts-dir" "and says what is missing"
}

test_setup_source_dry_run_changes_nothing_and_says_what_it_would_do() {
  setup
  inst src source
  local before; before="$(cat "$T/src/scripts/common/variables.txt")"
  mirror_run setup source --scripts-dir "$T/src/scripts" --dry-run
  assert_rc 0 "$RC" "dry run"
  assert_contains "$OUT" "[DRY-RUN]" "marked as a dry run"
  assert_contains "$OUT" "source-account" "the account step is listed"
  assert_contains "$OUT" "src-mirror-export.timer" "and the timer"
  assert_eq "$before" "$(cat "$T/src/scripts/common/variables.txt")" "variables.txt is unchanged"
  assert_missing "$T/mirror/root_helper.sh" "no code was copied"
  assert_missing "$T/units/src-mirror-export.timer" "no unit was written"
}

test_setup_source_installs_settings_code_and_an_export_timer_without_touching_the_server() {
  setup
  inst src source
  server_running
  mirror_run setup source --scripts-dir "$T/src/scripts" --export-at 03:30 --dims "minecraft/overworld minecraft/the_nether"
  assert_rc 0 "$RC" "set up"
  local v; v="$(cat "$T/src/scripts/common/variables.txt")"
  assert_contains "$v" 'MIRROR_ROLE="source"' "the role is stored"
  assert_contains "$v" 'MIRROR_DIMS="minecraft/overworld minecraft/the_nether"' "and the dimensions"
  assert_contains "$v" 'MIRROR_EXPORT_AT="03:30"' "and the time"
  assert_exists "$T/mirror/bin/export.sh" "the jobs are copied next to the instance, outside scripts/"
  assert_exists "$T/mirror/lib/timer_lib.sh" "with the timer library"
  assert_logged "root_helper.sh source-account --user $(id -un) --export-root $T/mirror/src/export" "the privileged account step is requested"
  local timer service
  timer="$(cat "$T/units/src-mirror-export.timer")"
  service="$(cat "$T/units/src-mirror-export.service")"
  assert_contains "$timer" "OnCalendar=*-*-* 03:30:00" "the export runs at the chosen time"
  assert_contains "$timer" "Persistent=true" "and catches up after downtime"
  assert_contains "$service" "export.sh" "the service runs the export job"
  assert_contains "$service" "ExecStopPost=" "with crash recovery"
  assert_contains "$service" '"--ensure-save-on"' "that re-enables saving"
  assert_not_logged "systemctl stop" "the server was not stopped"
  assert_not_logged "systemctl restart" "or restarted"
  assert_contains "$OUT" "the running server was not touched" "and the output says so"
}

test_homes_and_extras_options_are_stored_and_state_folders_are_refused() {
  setup
  inst src source
  mirror_run setup source --scripts-dir "$T/src/scripts" --homes
  assert_rc 0 "$RC" "--homes is accepted"
  assert_contains "$(cat "$T/src/scripts/common/variables.txt")" 'MIRROR_EXTRAS="modplayerdata essentialcommands"' "it stands for EssentialCommands' real homes and warps folders"
  mirror_run setup source --scripts-dir "$T/src/scripts" --extras "players"
  assert_nonzero "$RC" "a folder with server state is refused"
  mirror_run setup source --scripts-dir "$T/src/scripts" --extras "../etc"
  assert_nonzero "$RC" "and so is a path"
  inst tgt target
  mirror_run setup target --scripts-dir "$T/tgt/scripts" --source survival.example --sync-mods --extras "modplayerdata"
  assert_rc 0 "$RC" "a target takes the options too"
  assert_contains "$(cat "$T/tgt/scripts/common/variables.txt")" 'MIRROR_SYNC_MODS="true"' "the mods sync is stored"
}

test_setup_source_rejects_bad_options() {
  setup
  inst src source
  mirror_run setup source --scripts-dir "$T/src/scripts" --export-at 25:99
  assert_nonzero "$RC" "a bad time is refused"
  mirror_run setup source --scripts-dir "$T/src/scripts" --dims "minecraft/overworld ../x"
  assert_nonzero "$RC" "a bad dimension is refused"
  mirror_run setup source --scripts-dir "$T/src/scripts" --source-mode sideways
  assert_nonzero "$RC" "a bad mode is refused"
  assert_not_contains "$(cat "$T/src/scripts/common/variables.txt")" "MIRROR_" "nothing was written"
}

test_setup_target_creates_a_key_a_sudoers_request_and_a_pull_timer_and_prints_the_pairing_steps() {
  setup
  inst tgt target
  command -v ssh-keygen > /dev/null 2>&1 || { skip "setup target" "ssh-keygen is not installed"; return 0; }
  mirror_run setup target --scripts-dir "$T/tgt/scripts" --source survival.example --pull-at 05:20
  assert_rc 0 "$RC" "set up"
  assert_contains "$(cat "$T/tgt/scripts/common/variables.txt")" 'MIRROR_REMOTE="mcsync@survival.example"' "the source is stored"
  assert_exists "$T/mirror/tgt/ssh/id_ed25519" "a key was generated"
  assert_exists "$T/mirror/tgt/ssh/id_ed25519.pub" "with its public half"
  assert_logged "root_helper.sh target-sudoers --user $(id -un) --instance tgt" "the sudoers rule is requested"
  local timer service
  timer="$(cat "$T/units/tgt-mirror-pull.timer")"
  service="$(cat "$T/units/tgt-mirror-pull.service")"
  assert_contains "$timer" "OnCalendar=*-*-* 05:20:00" "the pull runs at the chosen time"
  assert_contains "$timer" "RandomizedDelaySec=300s" "with a random delay"
  assert_contains "$service" '"--recover"' "and recovery after a crash"
  assert_contains "$OUT" "mirror.sh authorize" "the authorize command is printed"
  assert_contains "$OUT" "mirror.sh pin-host" "and the host key pinning"
  # the private key never appears in the output
  assert_not_contains "$OUT" "BEGIN OPENSSH PRIVATE KEY" "no private key is printed"
  # running it again keeps the same key
  local before; before="$(cat "$T/mirror/tgt/ssh/id_ed25519.pub")"
  mirror_run setup target --scripts-dir "$T/tgt/scripts" --source survival.example
  assert_eq "$before" "$(cat "$T/mirror/tgt/ssh/id_ed25519.pub")" "a second setup keeps the key"
  assert_eq 1 "$(grep -c '^MIRROR_ROLE=' "$T/tgt/scripts/common/variables.txt")" "and the settings block"
}

test_setup_target_needs_a_source_and_valid_values() {
  setup
  inst tgt target
  mirror_run setup target --scripts-dir "$T/tgt/scripts"
  assert_nonzero "$RC" "no source is an error"
  mirror_run setup target --scripts-dir "$T/tgt/scripts" --source 'bad host;rm'
  assert_nonzero "$RC" "a host with shell characters is refused"
  mirror_run setup target --scripts-dir "$T/tgt/scripts" --source h --parity maybe
  assert_nonzero "$RC" "a bad parity setting is refused"
  mirror_run setup target --scripts-dir "$T/tgt/scripts" --source h --ssh-port 22x
  assert_nonzero "$RC" "a bad port is refused"
}

test_authorize_passes_the_export_folder_and_key_to_the_helper() {
  setup
  inst src source
  mirror_run authorize --scripts-dir "$T/src/scripts" --from 192.168.2.241 --key "$KEY"
  assert_rc 0 "$RC" "requested"
  assert_logged "root_helper.sh authorize --export-root $T/mirror/src/export --from 192.168.2.241" "the helper gets the export folder and address"
  mirror_run authorize --scripts-dir "$T/src/scripts" --from 192.168.2.241
  assert_nonzero "$RC" "a missing key is refused"
}

test_fingerprint_prints_without_an_instance() {
  setup
  if [[ ! -r /etc/ssh/ssh_host_ed25519_key.pub ]]; then skip "fingerprint" "this host has no ed25519 host key"; return 0; fi
  mirror_run fingerprint
  assert_rc 0 "$RC" "works"
  assert_contains "$OUT" "SHA256:" "prints a SHA256 fingerprint"
}

test_pin_host_refuses_a_fingerprint_that_does_not_match_and_a_missing_one_without_a_terminal() {
  setup
  inst tgt target
  command -v ssh-keygen > /dev/null 2>&1 || { skip "pin-host" "ssh-keygen is not installed"; return 0; }
  ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey" -C host
  local fp; fp="$(ssh-keygen -lf "$T/hostkey.pub" | awk '{print $2}')"
  { echo '#!/bin/bash'; echo "echo \"source.test $(cut -d' ' -f1,2 "$T/hostkey.pub")\""; } > "$T/bin/ssh-keyscan"
  chmod +x "$T/bin/ssh-keyscan"
  mirror_run pin-host --scripts-dir "$T/tgt/scripts" --host source.test
  assert_nonzero "$RC" "without a terminal and a fingerprint nothing is pinned"
  assert_contains "$OUT" "--fingerprint" "and the error says what to pass"
  mirror_run pin-host --scripts-dir "$T/tgt/scripts" --host source.test --fingerprint "SHA256:wrongwrongwrong"
  assert_nonzero "$RC" "a wrong fingerprint is refused"
  assert_contains "$OUT" "differs" "and called a difference"
  assert_missing "$T/mirror/tgt/ssh/known_hosts" "nothing was pinned"
  mirror_run pin-host --scripts-dir "$T/tgt/scripts" --host source.test --fingerprint "$fp"
  assert_rc 0 "$RC" "the right fingerprint pins the key"
  assert_contains "$(cat "$T/mirror/tgt/ssh/known_hosts")" "source.test ssh-ed25519" "the key is stored"
  mirror_run pin-host --scripts-dir "$T/tgt/scripts" --host 'bad host'
  assert_nonzero "$RC" "a host with a space is refused"
}

test_manage_mirror_delegates_to_the_installed_mirror_and_says_so_when_there_is_none() {
  setup
  local base="$T/mc"
  mkdir -p "$base/scripts/inst/common"
  # deployed layout: <target>/scripts/<instance>/manage.sh, the mirror at <target>/mirror
  cp "$REPO_ROOT/src/scripts/manage.sh" "$base/scripts/inst/manage.sh"
  cp "$T/scripts/common/variables.txt" "$base/scripts/inst/common/variables.txt"
  OUT="$(bash "$base/scripts/inst/manage.sh" mirror status inst 2>&1 < /dev/null)"; RC=$?
  assert_rc 1 "$RC" "without the mirror the command fails politely"
  assert_contains "$OUT" "The creative mirror is not installed. It is optional" "and says the mirror is optional"
  mkdir -p "$base/mirror"
  { echo '#!/bin/bash'; echo 'echo "mirror-called: $*"'; } > "$base/mirror/mirror.sh"
  OUT="$(bash "$base/scripts/inst/manage.sh" mirror status inst --extra 2>&1 < /dev/null)"; RC=$?
  assert_rc 0 "$RC" "with the mirror installed it is delegated to"
  assert_contains "$OUT" "mirror-called: status --scripts-dir $base/scripts/inst --extra" "the command, the instance's scripts folder and the extra arguments are passed on"
  OUT="$(bash "$base/scripts/inst/manage.sh" mirror status 2>&1 < /dev/null)"; RC=$?
  assert_rc 1 "$RC" "a missing instance is a usage error"
  OUT="$(bash "$base/scripts/inst/manage.sh" mirror status nosuch 2>&1 < /dev/null)"; RC=$?
  assert_rc 1 "$RC" "an unknown instance is refused"
  assert_contains "$OUT" "not found" "and called not found"
}

test_doctor_is_silent_about_an_instance_without_a_mirror_and_flags_missing_pieces_otherwise() {
  setup
  inst src source
  mirror_run doctor --scripts-dir "$T/src/scripts"
  assert_rc 0 "$RC" "no mirror is not a problem"
  assert_contains "$OUT" "[SKIP] mirror" "reported as skipped"
  mirror_run setup source --scripts-dir "$T/src/scripts"
  mirror_run doctor --scripts-dir "$T/src/scripts"
  assert_contains "$OUT" "[OK] mirror: enabled as source" "a configured mirror is reported"
  assert_contains "$OUT" "no snapshot yet" "a missing first export is a warning"
}

test_uninstall_removes_timers_settings_and_rules_but_keeps_the_state_unless_purged() {
  setup
  inst src source
  mirror_run setup source --scripts-dir "$T/src/scripts"
  assert_exists "$T/units/src-mirror-export.timer" "installed"
  mirror_run uninstall --scripts-dir "$T/src/scripts"
  assert_rc 0 "$RC" "uninstalled"
  assert_missing "$T/units/src-mirror-export.timer" "the timer is gone"
  assert_missing "$T/units/src-mirror-export.service" "and its service"
  assert_not_contains "$(cat "$T/src/scripts/common/variables.txt")" "MIRROR_" "the settings are gone"
  assert_logged "root_helper.sh remove-source" "the account step is undone"
  assert_exists "$T/mirror/src" "the state is kept"
  assert_exists "$T/src/server/world/level.dat" "and the world was never touched"
  mirror_run uninstall --scripts-dir "$T/src/scripts" --purge
  assert_missing "$T/mirror/src" "--purge removes the state"
}

# ── prepare.sh ───────────────────────────────────────────────────────────────

prep_setup() {
  setup
  mk_instance tgt target
  rm -rf "$T/tgt/server/world"
  mkdir -p "$T/tgt/server/mods"
  touch "$T/tgt/server/mods/fabric-api-0.165.0+26.3.jar"
  printf '{"gameVersion":"26.3"}' > "$T/tgt/scripts/common/downloaded_versions.json"
  printf 'level-seed=\ngamemode=survival\nforce-gamemode=true\nwhite-list=false\n' > "$T/tgt/server/server.properties"
  mirror_set "$T/tgt" RCON_PORT 25575
  export MIRROR_PREPARE_MODS=skip MIRROR_NODE="$REAL_NODE"
  [[ -n "$REAL_NODE" ]]
}

prepare() { OUT="$(bash "$MIRROR_SRC/prepare.sh" --scripts-dir "$T/tgt/scripts" "$@" 2>&1 < /dev/null)"; RC=$?; }
prop() { sed -n "s/^$1=//p" "$T/tgt/server/server.properties" | tail -n 1; }

test_prepare_sets_up_a_new_creative_instance() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  prepare --seed -446251370538060616
  assert_rc 0 "$RC" "prepared"
  assert_eq "-446251370538060616" "$(prop level-seed)" "the seed is the survival server's"
  assert_eq "creative" "$(prop gamemode)" "creative mode"
  assert_eq "false" "$(prop force-gamemode)" "force-gamemode is off, so the pools own the mode"
  assert_eq "deflate" "$(prop region-file-compression)" "the same compression on both servers"
  assert_eq "true" "$(prop enable-rcon)" "RCON is on"
  assert_eq "false" "$(prop white-list)" "settings it does not own are left alone"
  assert_eq 1 "$(grep -c '^gamemode=' "$T/tgt/server/server.properties")" "no key is duplicated"
  local pw; pw="$(prop rcon.password)"
  assert_eq 32 "${#pw}" "a generated RCON password"
  assert_contains "$(cat "$T/tgt/scripts/common/variables.txt")" "RCON_PASSWORD=\"$pw\"" "the suite's scripts know the same password"
  assert_contains "$(cat "$T/tgt/scripts/common/variables.txt")" 'USE_RCON="true"' "and use RCON"
  assert_eq "manage-gamemode=false" "$(cat "$T/tgt/server/config/fabricplots.properties")" "FabricPlots leaves the game mode to the pools"
  local pools="$T/tgt/server/world/dimensional-inventories/v2/config/main/dimension-pools.json"
  assert_exists "$pools" "the pools are written before the first start"
  assert_eq 3 "$(grep -c '"gameMode": "CREATIVE"' "$pools")" "all three pools are creative"
  assert_contains "$(cat "$pools")" '"fabricplots:plots"' "the plots dimension has its own pool"
  assert_not_contains "$OUT" "$pw" "the password is not printed"
}

test_prepare_lets_every_player_use_gamemode_through_luckperms_and_never_overwrites_rules() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  local lp="$T/tgt/server/config/luckperms"
  prepare --seed 9
  assert_rc 0 "$RC" "prepared"
  assert_eq 'storage-method = "json"' "$(cat "$lp/luckperms.conf")" "LuckPerms keeps its data in JSON so the group can be written first"
  assert_contains "$(cat "$lp/json-storage/groups/default.json")" '"permission": "minecraft.command.gamemode"' "the default group may use /gamemode"
  assert_contains "$OUT" "every player may use /gamemode" "and the output says so"
  echo "admin-rules" > "$lp/json-storage/groups/default.json"
  echo "admin-conf" > "$lp/luckperms.conf"
  rm -rf "$T/tgt/server/world"
  prepare --seed 9
  assert_eq "admin-rules" "$(cat "$lp/json-storage/groups/default.json")" "an existing group is left as it is"
  assert_eq "admin-conf" "$(cat "$lp/luckperms.conf")" "and so are the settings"
}

test_prepare_can_skip_the_permissions() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  prepare --seed 9 --no-permissions
  assert_rc 0 "$RC" "prepared"
  assert_missing "$T/tgt/server/config/luckperms" "no LuckPerms files"
  rm -rf "$T/tgt/server/world"
  prepare --seed 9 --dry-run
  assert_missing "$T/tgt/server/config/luckperms" "a dry run writes nothing"
  assert_contains "$OUT" "would let every player use /gamemode" "but says what it would do"
}

test_prepare_needs_a_seed_and_refuses_a_bad_one() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  prepare
  assert_nonzero "$RC" "no seed is an error"
  assert_contains "$OUT" "pass --seed" "and says what to do"
  prepare --seed 12ab
  assert_nonzero "$RC" "a non-numeric seed is refused"
  assert_eq "" "$(prop level-seed)" "nothing was written"
  printf 'level-seed=555\n' > "$T/tgt/server/server.properties"
  prepare
  assert_rc 0 "$RC" "a seed already in server.properties is used"
  assert_eq "555" "$(prop level-seed)" "and kept"
}

test_prepare_refuses_an_existing_world_unless_forced_and_never_changes_its_seed() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  mirror_world "$T/tgt/server" existing 1
  printf 'level-name=world\nlevel-seed=111\n' > "$T/tgt/server/server.properties"
  prepare --seed 222
  assert_nonzero "$RC" "an existing world is refused"
  assert_contains "$OUT" "seed cannot be changed on an existing world" "with the reason"
  assert_eq "111" "$(prop level-seed)" "nothing was edited"
  prepare --seed 222 --force
  assert_rc 0 "$RC" "forced"
  assert_eq "111" "$(prop level-seed)" "the seed of the existing world is untouched"
  assert_eq "creative" "$(prop gamemode)" "the rest is prepared"
  assert_eq "existing-border" "$(cat "$T/tgt/server/world/dimensions/minecraft/overworld/data/minecraft/world_border.dat")" "the world itself is untouched"
}

test_prepare_refuses_a_running_server() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  server_running
  prepare --seed 5
  assert_nonzero "$RC" "a running server is refused"
  assert_contains "$OUT" "is running" "and named"
  assert_eq "" "$(prop level-seed)" "nothing was edited"
}

test_prepare_dry_run_changes_nothing() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  local before; before="$(cat "$T/tgt/server/server.properties")$(cat "$T/tgt/scripts/common/variables.txt")"
  prepare --seed 5 --dry-run
  assert_rc 0 "$RC" "dry run"
  assert_contains "$OUT" "server.properties: gamemode=creative" "the edits are listed"
  assert_eq "$before" "$(cat "$T/tgt/server/server.properties")$(cat "$T/tgt/scripts/common/variables.txt")" "no file changed"
  assert_missing "$T/tgt/server/config/fabricplots.properties" "and nothing was created"
}

test_prepare_turns_off_c2me_on_a_new_server_through_the_suites_own_toggle() {
  prep_setup || { skip "prepare" "node is not available"; return 0; }
  mkdir -p "$T/tgt/scripts/update"
  cat > "$T/tgt/scripts/update/toggle-mod.js" <<JS
require("fs").appendFileSync("$T/toggle.log", process.argv.slice(2).join(" ") + "\n");
JS
  prepare --seed 5
  assert_rc 0 "$RC" "prepared"
  assert_eq "c2me-fabric --disable" "$(cat "$T/toggle.log")" "the suite's toggle script is used, so its bookkeeping stays right"
  assert_contains "$OUT" "C2ME is disabled" "and the output says so"
}

run_tests
