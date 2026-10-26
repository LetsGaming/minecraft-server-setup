#!/bin/bash
# Wizard manifest and engine, driven by the scriptable whiptail shim (WHIPTAIL_SHIM_REPLIES).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin" "$T/state"
  cp "$HERE/shims/whiptail" "$T/bin/"
  chmod +x "$T/bin/whiptail"
  export SHIM_LOG="$T/shim.log" SHIM_STATE="$T/state"
  : > "$SHIM_LOG"
  export PATH="$T/bin:$PATH"
  export MC_SETUP_TERM_SIZE="30 100" TERM=xterm MC_SETUP_FORCE_TTY=1
}

load_wizard() {
  source "$REPO/src/common/detect.sh"
  source "$REPO/src/wizard/whiptail.sh"
  source "$REPO/src/wizard/validators.sh"
  source "$REPO/src/wizard/manifest.sh"
  source "$REPO/src/wizard/engine.sh"
}

# Replies for the guided steps after server_kind when it is not a modpack (12 steps,
# the last one is the creative mirror question, answered no).
REST_REPLIES=$'0|1.21.4\n0|6G\n0|20\n0|Hello\n0|hard\n1|\n0|optional\n1|\n1|\n0|https://example.com/hook\n1|\n1|'

# The same without the Minecraft version step, which a modpack does not ask.
MODPACK_REST_REPLIES="${REST_REPLIES#*$'\n'}"

# Prints "rc=<n>" then one "key=value" per answer, sorted; extra args are VAR=value exports.
run_engine() { # route, replies (newline separated), VAR=value...
  local route="$1" replies="$2" out rc=0 key
  shift 2
  printf '%s\n' "$replies" > "$T/replies"
  rm -f "$T/state/whiptail.count"
  out="$(
    export WHIPTAIL_SHIM_REPLIES="$T/replies"
    for assignment in "$@"; do export "${assignment?}"; done
    load_wizard
    if [ -n "${AFTER_LOAD:-}" ]; then "$AFTER_LOAD"; fi
    engine_run "$route" 2>/dev/null || rc=$?
    echo "rc=$rc"
    for key in "${!ANSWERS[@]}"; do echo "$key=${ANSWERS[$key]}"; done | sort
  )"
  echo "$out"
}

extra_entry() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    extra_step EXTRA.SETTING string input fallback default "" "" "Extra" "A test-only step."
}

wizard_manifest_with_extra() { wizard_manifest() { extra_entry; }; }

test_collects_answers_by_json_path() {
  setup
  local out
  out="$(run_engine guided $'0|my-server\n0|fabric\n'"$REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "INSTANCE_NAME=my-server" "string answer"
  assert_contains "$out" "server_kind=fabric" "pseudo-key step keyed by id"
  assert_contains "$out" "JAVA.SERVER.VANILLA.VERSION=1.21.4" "dotted path key"
  assert_contains "$out" "memory=6G" "memory pseudo-key"
  assert_contains "$out" "JAVA.SERVER.MAX_PLAYERS=20" "number answer"
  assert_contains "$out" "JAVA.SERVER.MOTD=Hello" "motd"
  assert_contains "$out" "JAVA.SERVER.DIFFICULTY=hard" "radiolist answer"
  assert_contains "$out" "JAVA.SERVER.WHITELIST=false" "yes/no stored as false"
  assert_contains "$out" "optional_mods=optional" "checklist answer"
  assert_contains "$out" "backups=false" "backups"
  assert_contains "$out" "NOTIFICATIONS.WEBHOOK_URL=https://example.com/hook" "webhook"
  assert_contains "$out" "API_SERVER.ENABLED=false" "api wrapper"
  assert_not_contains "$out" "curseforge" "modpack steps not asked"
}

test_yes_answer_is_stored_as_true() {
  setup
  local out
  out="$(run_engine guided $'0|my-server\n0|fabric\n0|latest\n0|4G\n0|10\n0|msg\n0|normal\n0|\n0|\n0|\n0|\n0|\n0|')"
  assert_contains "$out" "JAVA.SERVER.WHITELIST=true" "yes becomes true"
  assert_contains "$out" "backups=true" "backups yes"
}

test_default_route_asks_nothing() {
  setup
  local out
  out="$(run_engine default "")"
  assert_eq "rc=0" "$out" "no steps, no answers"
  assert_eq "" "$(cat "$SHIM_LOG")" "whiptail never called"
}

test_back_returns_to_previous_step() {
  setup
  local out
  out="$(run_engine guided $'0|first\n1|\n0|second\n0|fabric\n'"$REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "INSTANCE_NAME=second" "name asked again after Back"
  assert_contains "$out" "server_kind=fabric" "continued after the re-answer"
}

test_back_on_first_step_asks_it_again() {
  setup
  local out
  out="$(run_engine guided $'1|\n0|again\n0|fabric\n'"$REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "INSTANCE_NAME=again" "first step re-asked"
}

test_back_skips_hidden_steps() {
  setup
  # kind=fabric hides both modpack steps; Back from minecraft_version must land on server_kind.
  local out
  out="$(run_engine guided $'0|n\n0|fabric\n1|\n0|vanilla\n'"$REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "server_kind=vanilla" "returned to server_kind, not a hidden step"
}

test_invalid_answer_reasks_with_message() {
  setup
  local out
  out="$(run_engine guided $'0|bad name\n0|\n0|good-name\n0|fabric\n'"$REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "INSTANCE_NAME=good-name" "valid answer kept"
  assert_logged "not a valid name" "validator message shown in a msgbox"
  assert_logged "--msgbox" "msgbox widget used"
}

test_when_condition_hides_modpack_steps() {
  setup
  local out
  out="$(run_engine guided $'0|n\n0|fabric\n'"$REST_REPLIES")"
  assert_not_contains "$out" "curseforge_key" "key hidden for fabric"
  assert_not_contains "$out" "curseforge_pack" "pack hidden for fabric"
  setup
  out="$(run_engine guided $'0|n\n0|modpack\n0|secret-key\n0|123456\n'"$MODPACK_REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "curseforge_key=secret-key" "key asked for modpack"
  assert_contains "$out" "curseforge_pack=123456" "pack asked for modpack"
}

test_negated_when_hides_the_minecraft_version_for_modpacks() {
  setup
  local out
  out="$(run_engine guided $'0|n\n0|modpack\n0|k\n0|123456\n'"$MODPACK_REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished with one step fewer"
  assert_not_contains "$out" "JAVA.SERVER.VANILLA.VERSION" "version not asked for a modpack"
  assert_contains "$out" "memory=6G" "later steps still line up"
  setup
  out="$(run_engine guided $'0|n\n0|vanilla\n'"$REST_REPLIES")"
  assert_contains "$out" "JAVA.SERVER.VANILLA.VERSION=1.21.4" "version asked for vanilla"
}

test_negated_when_is_generic_and_back_skips_it() {
  setup
  local out
  out="$(
    load_wizard
    declare -gA _ENGINE_BY_ID=([server_kind]=modpack)
    _engine_when_met "server_kind!=modpack" && echo shown-for-modpack
    _engine_when_met "server_kind!=fabric" && echo shown-for-other
    _engine_when_met "missing!=x" && echo shown-when-unanswered
    _engine_when_met "server_kind=modpack" && echo equals-still-works
  )"
  assert_eq $'shown-for-other\nshown-when-unanswered\nequals-still-works' "$out" "negated and plain conditions"
  out="$(
    load_wizard
    declare -gA _ENGINE_BY_ID=([a]="b!=c" [e]="" [f]="x=y")
    _engine_when_met "a=b!=c" && echo equals-with-bang-in-value
    _engine_when_met "a!=b!=c" && echo wrong-negated-bang-value
    _engine_when_met "a!=z!=c" && echo negated-bang-value
    _engine_when_met "e!=" && echo wrong-empty-negated
    _engine_when_met "e=" && echo empty-equals
    _engine_when_met "missing!=" && echo wrong-unanswered-empty
    _engine_when_met "f!=x=z" && echo negated-equals-in-value
    _engine_when_met "f!=x=y" && echo wrong-negated-equals-match
    _engine_when_met "f=x=y" && echo equals-equals-in-value
  )"
  assert_eq $'equals-with-bang-in-value\nnegated-bang-value\nempty-equals\nnegated-equals-in-value\nequals-equals-in-value' "$out" "operator is the first one in the condition"
  setup
  out="$(run_engine guided $'0|n\n0|modpack\n0|k\n0|123456\n1|\n0|777\n'"$MODPACK_REST_REPLIES")"
  assert_contains "$out" "curseforge_pack=777" "back from memory skipped the hidden version step"
}

test_changing_kind_back_drops_modpack_answers() {
  setup
  local out
  out="$(run_engine guided $'0|n\n0|modpack\n0|secret-key\n1|\n1|\n0|fabric\n'"$REST_REPLIES")"
  assert_contains "$out" "rc=0" "finished"
  assert_not_contains "$out" "curseforge" "stale modpack answers removed"
}

test_cancel_returns_11() {
  setup
  local out
  out="$(run_engine guided $'0|n\n255|')"
  assert_contains "$out" "rc=11" "cancel"
  setup
  out="$(run_engine guided $'0|bad name\n255|')"
  assert_contains "$out" "rc=11" "cancel on the validation message"
}

test_unavailable_mid_run_returns_12() {
  setup
  local out
  printf '%s\n' $'0|n\n0|fabric\n0|latest' > "$T/replies"
  out="$(
    export WHIPTAIL_SHIM_REPLIES="$T/replies"
    load_wizard
    wt_available() {
      local n=0
      [ -f "$T/avail" ] && n="$(<"$T/avail")"
      echo $(( n + 1 )) > "$T/avail"
      [ "$n" -lt 2 ]
    }
    rc=0
    engine_run guided 2>/dev/null || rc=$?
    echo "rc=$rc"
  )"
  assert_eq "rc=12" "$out" "returns 12 when whiptail goes away"
}

test_engine_available_follows_wt_available() {
  setup
  load_wizard
  local rc=0
  engine_available || rc=$?
  assert_rc 0 "$rc" "whiptail present"
  rc=0
  MC_SETUP_TERM_SIZE="10 20" engine_available || rc=$?
  assert_rc 1 "$rc" "small terminal"
}

test_adding_a_manifest_entry_needs_no_engine_change() {
  setup
  local out
  out="$(run_engine default $'0|typed-value' AFTER_LOAD=wizard_manifest_with_extra)"
  assert_contains "$out" "rc=0" "finished"
  assert_contains "$out" "EXTRA.SETTING=typed-value" "extra record answered and keyed by its json path"
  assert_logged "fallback" "default value from the record offered"
}

test_manifest_records_are_well_formed() {
  setup
  load_wizard
  local record id fields n=0
  local -A seen=()
  while IFS= read -r record; do
    _engine_split "$record"
    assert_eq 10 "${#_ENGINE_F[@]}" "ten fields in: ${record%%$'\t'*}"
    id="${_ENGINE_F[0]}"
    assert_eq "" "${seen[$id]:-}" "id $id is unique"
    seen[$id]=1
    case "${_ENGINE_F[2]}" in string | number | bool | list) ;; *) assert_eq ok "bad type ${_ENGINE_F[2]}" "type of $id" ;; esac
    case "${_ENGINE_F[3]%%:*}" in input | password | yesno | menu | radiolist | checklist) ;; *) assert_eq ok "bad widget ${_ENGINE_F[3]}" "widget of $id" ;; esac
    n=$(( n + 1 ))
  done < <(wizard_manifest)
  assert_eq 18 "$n" "guided steps present"
  fields="$(wizard_manifest | cut -f1 | tr '\n' ' ')"
  assert_contains "$fields" "instance_name server_kind" "ids in order"
  assert_not_contains "$(wizard_manifest | cut -f6)" "default" "Default route shows no steps"
}

test_every_manifest_validator_exists() {
  setup
  load_wizard
  local record spec name list missing=""
  local -a specs
  while IFS= read -r record; do
    _engine_split "$record"
    list="${_ENGINE_F[6]}"
    [ -n "$list" ] || continue
    IFS=, read -r -a specs <<< "$list"
    for spec in "${specs[@]}"; do
      name="${spec%%:*}"
      declare -F "$name" > /dev/null || missing="$missing $name"
    done
  done < <(wizard_manifest)
  assert_eq "" "$missing" "unknown validators (run_validators would silently skip them)"
}

test_every_manifest_detector_exists() {
  setup
  load_wizard
  local record spec missing=""
  while IFS= read -r record; do
    _engine_split "$record"
    spec="${_ENGINE_F[4]}"
    case "$spec" in detect:*) declare -F "${spec#detect:}" > /dev/null || missing="$missing $spec" ;; esac
  done < <(wizard_manifest)
  assert_eq "" "$missing" "unknown detectors"
}

run_tests
