#!/bin/bash
# The optional creative mirror: a creative server whose overworld is refreshed
# nightly from a survival server's chunk files. Nothing in the suite depends on
# it; run `mirror.sh help` for the commands, docs/mirror.md for the walk-through.
#
# Runs as the server owner (never as root); the few privileged steps go through
# `sudo bash root_helper.sh`.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From a checkout the code is under src/mirror; the installed copy is flat.
if [[ -d "$HERE/src/mirror" ]]; then
  CODE_DIR="$HERE/src/mirror"
  TIMER_LIB="$HERE/src/setup/management/timer_lib.sh"
else
  CODE_DIR="$HERE"
  TIMER_LIB="$HERE/lib/timer_lib.sh"
fi
# shellcheck source=src/mirror/lib/config.sh
source "$CODE_DIR/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: mirror.sh <command> [options]
  Every command needs --scripts-dir DIR (the instance's deployed scripts folder)
  or --instance NAME (found below your home folder).

Setup
  setup source|target     install the mirror on this server (never restarts it)
      source: --source-mode live|stage  --dims "minecraft/overworld"  --export-at HH:MM  --extras "folder ..." | --homes
      target: --source HOST  --ssh-port N  --pull-at HH:MM  --parity warn|refuse|off  --bwlimit KIB
              --extras "folder ..." | --homes   --sync-mods (run the source's mods)
  prepare                 prepare a NEW creative instance (properties, pinned mods, pools)
  authorize               (source) allow the target's key: --from ADDR --key "ssh-ed25519 ..."
  fingerprint             (source) print this host's SSH host key fingerprint
  pin-host                (target) pin the source's host key: --host H [--fingerprint SHA256:...]
  test                    (target) check the link: listing works, writes and escapes are refused

Operation
  export | pull [...]     run a job now (see the job's --help)
  status | doctor         what is configured and whether it is healthy
  uninstall [--purge]     remove timers, rules and the account; --purge also the state

Common: --dry-run  show what would change, change nothing
EOF
}

die() { echo "[mirror] ERROR: $*" >&2; exit 1; }
say() { echo "[mirror] $*"; }

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift
case "$COMMAND" in help | -h | --help) usage; exit 0 ;; esac

ROLE_ARG=""
if [[ "$COMMAND" == setup ]]; then
  ROLE_ARG="${1:-}"
  [[ "$ROLE_ARG" == source || "$ROLE_ARG" == target ]] || die "setup needs a role: source or target"
  shift
fi

SCRIPTS_DIR="" INSTANCE_ARG="" DRY_RUN=false PURGE=false
O_SOURCE_MODE="" O_DIMS="" O_EXPORT_AT="" O_SOURCE="" O_SSH_PORT="" O_PULL_AT="" O_PARITY="" O_BWLIMIT=""
O_EXTRAS="" O_SYNC_MODS="" O_FROM="" O_KEY="" O_HOST="" O_FINGERPRINT="" O_SEED="" O_FORCE=false
PASS_ARGS=()
while (($#)); do
  case "$1" in
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2 ;;
    --instance) INSTANCE_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; PASS_ARGS+=("$1"); shift ;;
    --purge) PURGE=true; shift ;;
    --source-mode) O_SOURCE_MODE="$2"; shift 2 ;;
    --dims) O_DIMS="$2"; shift 2 ;;
    --export-at) O_EXPORT_AT="$2"; shift 2 ;;
    --source) O_SOURCE="$2"; shift 2 ;;
    --ssh-port) O_SSH_PORT="$2"; shift 2 ;;
    --pull-at) O_PULL_AT="$2"; shift 2 ;;
    --parity) O_PARITY="$2"; shift 2 ;;
    --bwlimit) O_BWLIMIT="$2"; shift 2 ;;
    --extras) O_EXTRAS="$2"; shift 2 ;;
    --homes) O_EXTRAS="ec_player_profiles essentialcommands"; shift ;;
    --sync-mods) O_SYNC_MODS=true; shift ;;
    --from) O_FROM="$2"; shift 2 ;;
    --key) O_KEY="$2"; shift 2 ;;
    --host) O_HOST="$2"; shift 2 ;;
    --fingerprint) O_FINGERPRINT="$2"; shift 2 ;;
    --seed) O_SEED="$2"; shift 2 ;;
    --force) O_FORCE=true; PASS_ARGS+=("$1"); shift ;;
    *) PASS_ARGS+=("$1"); shift ;;
  esac
done

[[ "$(id -u)" != 0 || "${MC_MIRROR_ALLOW_ROOT:-}" == 1 ]] || die "run this as the server's user, not as root (it uses sudo where it must)"

resolve_instance() {
  if [[ -z "$SCRIPTS_DIR" && -n "$INSTANCE_ARG" ]]; then
    local found=()
    local f
    for f in "$HOME"/*/scripts/"$INSTANCE_ARG"/common/variables.txt; do
      [[ -f "$f" ]] && found+=("$(dirname "$(dirname "$f")")")
    done
    ((${#found[@]} == 1)) || die "found ${#found[@]} instances named '$INSTANCE_ARG' below $HOME; pass --scripts-dir"
    SCRIPTS_DIR="${found[0]}"
  fi
  [[ -n "$SCRIPTS_DIR" ]] || die "pass --scripts-dir DIR or --instance NAME"
  SCRIPTS_DIR="$(cd "$SCRIPTS_DIR" 2> /dev/null && pwd)" || die "scripts folder not found"
  VARS_FILE="$SCRIPTS_DIR/common/variables.txt"
  [[ -f "$VARS_FILE" ]] || die "$VARS_FILE not found: is that an instance's deployed scripts folder?"
  INSTANCE_NAME="$(mirror_config_value "$VARS_FILE" INSTANCE_NAME)"
  SERVER_PATH="$(mirror_config_value "$VARS_FILE" SERVER_PATH)"
  BACKUPS_PATH="$(mirror_config_value "$VARS_FILE" BACKUPS_PATH)"
  RUN_USER="$(mirror_config_value "$VARS_FILE" USER)"
  [[ -n "$INSTANCE_NAME" && -n "$SERVER_PATH" ]] || die "variables.txt has no INSTANCE_NAME or SERVER_PATH"
  BASE_DIR="$(cd "$SCRIPTS_DIR/../.." && pwd)"
  MIRROR_HOME="${MIRROR_HOME:-$BASE_DIR/mirror}"
  STATE="$MIRROR_HOME/$INSTANCE_NAME"
  EXPORT_ROOT="$STATE/export"
  SYNC_ROOT="$STATE/sync"
  SSH_DIR="$STATE/ssh"
}

# run <command...>: the command, or a line saying what it would do.
run() { if $DRY_RUN; then echo "[DRY-RUN] $*"; else "$@"; fi; }
root_helper() { run sudo bash "$MIRROR_HOME/root_helper.sh" "$@"; }

cfg() { mirror_config_value "$VARS_FILE" "$1"; }
cfg_or() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }

valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

# World folders that hold this server's own state are never mirrored (same list as
# src/mirror/lib/common.sh).
valid_extras() {
  local x deny='^(dimensions|players|playerdata|advancements|stats|data|datapacks|region|entities|poi|dimensional-inventories|level\.dat.*|session\.lock|\.|\.\.)$'
  for x in $1; do
    [[ "$x" =~ ^[A-Za-z0-9_.-]+$ && ! "$x" =~ $deny ]] || die "--extras may only list plain world folder names that are not server state (got $x)"
  done
}

# Copies the mirror's code next to the instance's folders, outside scripts/<instance>
# so migrate.sh never replaces it.
install_code() {
  local d
  [[ "$HERE" != "$MIRROR_HOME" ]] || return 0
  if $DRY_RUN; then echo "[DRY-RUN] copy the mirror code to $MIRROR_HOME"; return 0; fi
  mkdir -p "$MIRROR_HOME/bin" "$MIRROR_HOME/lib"
  for d in bin lib; do cp -f "$CODE_DIR/$d/"*.sh "$MIRROR_HOME/$d/"; done
  cp -f "$CODE_DIR/root_helper.sh" "$MIRROR_HOME/root_helper.sh"
  [[ -f "$CODE_DIR/prepare.sh" ]] && cp -f "$CODE_DIR/prepare.sh" "$MIRROR_HOME/prepare.sh"
  [[ -f "$CODE_DIR/prepare_mods.js" ]] && cp -f "$CODE_DIR/prepare_mods.js" "$MIRROR_HOME/prepare_mods.js"
  [[ -f "$CODE_DIR/pins.json" ]] && cp -f "$CODE_DIR/pins.json" "$MIRROR_HOME/pins.json"
  cp -f "$TIMER_LIB" "$MIRROR_HOME/lib/timer_lib.sh"
  cp -f "$HERE/mirror.sh" "$MIRROR_HOME/mirror.sh"
  chmod 755 "$MIRROR_HOME/bin/"*.sh "$MIRROR_HOME/mirror.sh"
  chmod 700 "$MIRROR_HOME"
}

write_config() { # role, then KEY=VALUE pairs
  local role="$1"
  shift
  if $DRY_RUN; then
    echo "[DRY-RUN] write the mirror settings to $VARS_FILE:"
    printf '[DRY-RUN]   %s\n' "$@"
    return 0
  fi
  mirror_config_write "$VARS_FILE" "MIRROR_ENABLED=true" "MIRROR_ROLE=$role" "$@"
}

install_timer() { # suffix description script calendar log persistent delay -- exec args...
  local suffix="$1" desc="$2" script="$3" calendar="$4" log="$5" persistent="$6" delay="$7"
  if $DRY_RUN; then echo "[DRY-RUN] install the timer $INSTANCE_NAME-$suffix.timer ($calendar)"; return 0; fi
  mkdir -p "$(dirname "$log")"
  # shellcheck source=src/setup/management/timer_lib.sh
  (
    export INSTANCE_NAME USER="$RUN_USER"
    source "$MIRROR_HOME/lib/timer_lib.sh"
    timer_install "$suffix" "$desc" "$script" "$calendar" "$log" "$persistent" "$SCRIPTS_DIR" "$delay"
  )
}

warn_worldgen_mods() {
  local mods
  mods="$(find "$SERVER_PATH/mods" -maxdepth 1 -type f -name '*.jar' -printf '%f\n' 2> /dev/null | grep -iE "$(cfg_or MIRROR_WORLDGEN_MODS 'c2me|terralith|tectonic|lithostitched|nullscape|incendium|biomesoplenty|worldgen')" | paste -sd ' ' -)" || true
  if [[ -n "$mods" ]]; then
    say "NOTE: mods that change world generation are installed here: $mods"
    say "      Chunks generated later only match the other server when both run the same ones."
    say "      In a test, C2ME alone made about three times as many blocks differ. Consider removing it on both servers."
  fi
}

cmd_setup_source() {
  local mode dims at pairs
  mode="${O_SOURCE_MODE:-$(cfg_or MIRROR_SOURCE_MODE live)}"
  dims="${O_DIMS:-$(cfg_or MIRROR_DIMS minecraft/overworld)}"
  at="${O_EXPORT_AT:-$(cfg_or MIRROR_EXPORT_AT 04:40)}"
  [[ "$mode" == live || "$mode" == stage ]] || die "--source-mode must be live or stage"
  valid_time "$at" || die "--export-at must be HH:MM"
  local dim
  for dim in $dims; do
    [[ "$dim" =~ ^minecraft/(overworld|the_nether|the_end)$ ]] || die "--dims may only list minecraft/overworld, minecraft/the_nether, minecraft/the_end"
  done
  command -v rsync > /dev/null 2>&1 || die "rsync is not installed"
  if [[ "$mode" == stage && "$(cfg BACKUP_STAGING_MODE)" != mirror ]]; then
    say "NOTE: stage mode copies the backup's staging mirror, which only exists with BACKUP_STAGING_MODE=mirror (it is '$(cfg_or BACKUP_STAGING_MODE auto)')."
  fi
  local extras
  extras="${O_EXTRAS:-$(cfg MIRROR_EXTRAS)}"
  valid_extras "$extras"
  install_code
  write_config source "MIRROR_SOURCE_MODE=$mode" "MIRROR_DIMS=$dims" "MIRROR_EXPORT_AT=$at" "MIRROR_EXTRAS=$extras"
  run mkdir -p "$STATE/logs"
  root_helper source-account --user "$RUN_USER" --export-root "$EXPORT_ROOT"
  TIMER_EXEC_ARGS=(--scripts-dir "$SCRIPTS_DIR")
  TIMER_STOPPOST_ARGS=("$MIRROR_HOME/bin/export.sh" --scripts-dir "$SCRIPTS_DIR" --ensure-save-on)
  install_timer mirror-export "Mirror export of $INSTANCE_NAME" "$MIRROR_HOME/bin/export.sh" "*-*-* $at:00" "$STATE/logs/export.log" true 0
  warn_worldgen_mods
  say "The source side is ready; the running server was not touched."
  say "Next: on the creative server run 'mirror.sh setup target --source <this host>', then authorize its key here:"
  say "  mirror.sh authorize --instance $INSTANCE_NAME --from <creative address> --key \"<its public key>\""
  say "This host's SSH fingerprint (compare it when pinning): $(fingerprint_line)"
}

local_addresses() { hostname -I 2> /dev/null | awk '{print $1}'; }

cmd_setup_target() {
  local remote host port at parity bw
  host="${O_SOURCE:-}"
  remote="${host:+mcsync@$host}"
  remote="${remote:-$(cfg MIRROR_REMOTE)}"
  [[ -n "$remote" ]] || die "pass --source HOST (the survival server)"
  [[ "$remote" =~ ^mcsync@[A-Za-z0-9._:-]+$ ]] || die "the source host may only contain letters, digits and . _ : -"
  port="${O_SSH_PORT:-$(cfg_or MIRROR_SSH_PORT 22)}"
  at="${O_PULL_AT:-$(cfg_or MIRROR_PULL_AT 05:15)}"
  parity="${O_PARITY:-$(cfg_or MIRROR_PARITY warn)}"
  bw="${O_BWLIMIT:-$(cfg_or MIRROR_BWLIMIT_KIB 40000)}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "--ssh-port must be a number"
  valid_time "$at" || die "--pull-at must be HH:MM"
  [[ "$parity" == warn || "$parity" == refuse || "$parity" == off ]] || die "--parity must be warn, refuse or off"
  [[ "$bw" =~ ^[0-9]+$ ]] || die "--bwlimit must be a number (KiB/s, 0 = unlimited)"
  command -v rsync > /dev/null 2>&1 || die "rsync is not installed"
  command -v ssh > /dev/null 2>&1 || die "the ssh client is not installed"
  local extras sync
  extras="${O_EXTRAS:-$(cfg MIRROR_EXTRAS)}"
  valid_extras "$extras"
  sync="${O_SYNC_MODS:-$(cfg_or MIRROR_SYNC_MODS false)}"
  install_code
  write_config target "MIRROR_REMOTE=$remote" "MIRROR_SSH_PORT=$port" "MIRROR_PULL_AT=$at" "MIRROR_PARITY=$parity" "MIRROR_BWLIMIT_KIB=$bw" "MIRROR_EXTRAS=$extras" "MIRROR_SYNC_MODS=$sync"
  run mkdir -p "$SSH_DIR" "$STATE/logs"
  run chmod 700 "$SSH_DIR"
  if [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
    run ssh-keygen -q -t ed25519 -a 100 -N '' -C "mc-mirror@$INSTANCE_NAME" -f "$SSH_DIR/id_ed25519"
  fi
  root_helper target-sudoers --user "$RUN_USER" --instance "$INSTANCE_NAME"
  TIMER_EXEC_ARGS=(--scripts-dir "$SCRIPTS_DIR")
  TIMER_STOPPOST_ARGS=("$MIRROR_HOME/bin/pull.sh" --scripts-dir "$SCRIPTS_DIR" --recover)
  install_timer mirror-pull "Mirror pull for $INSTANCE_NAME" "$MIRROR_HOME/bin/pull.sh" "*-*-* $at:00" "$STATE/logs/pull.log" true 300
  warn_worldgen_mods
  say "The target side is ready; the running server was not touched."
  say "Next, on the survival server, authorize this server's key (read-only):"
  if [[ -f "$SSH_DIR/id_ed25519.pub" ]]; then
    say "  mirror.sh authorize --instance <survival instance> --from $(local_addresses) --key \"$(cut -d' ' -f1,2 "$SSH_DIR/id_ed25519.pub")\""
  fi
  say "Then pin the survival host key here, comparing the fingerprint printed on the survival server:"
  say "  mirror.sh pin-host --instance $INSTANCE_NAME --host ${remote#mcsync@} --fingerprint SHA256:..."
  say "And check the link: mirror.sh test --instance $INSTANCE_NAME"
}

fingerprint_line() {
  local f=/etc/ssh/ssh_host_ed25519_key.pub
  if [[ -r "$f" ]]; then
    ssh-keygen -lf "$f" | awk '{print $2}'
    return 0
  fi
  echo "(no ed25519 host key found in /etc/ssh)"
}

cmd_fingerprint() { fingerprint_line; }

cmd_authorize() {
  [[ -n "$O_FROM" && -n "$O_KEY" ]] || die "authorize needs --from ADDR and --key \"ssh-ed25519 ...\""
  root_helper authorize --export-root "$EXPORT_ROOT" --from "$O_FROM" --key "$O_KEY"
}

cmd_pin_host() {
  [[ -n "$O_HOST" ]] || die "pin-host needs --host HOST"
  [[ "$O_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "the host may only contain letters, digits and . _ : -"
  local port tmp fp
  port="$(cfg_or MIRROR_SSH_PORT 22)"
  command -v ssh-keyscan > /dev/null 2>&1 || die "ssh-keyscan is not installed"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  ssh-keyscan -t ed25519 -p "$port" "$O_HOST" 2> /dev/null > "$tmp" || true
  [[ -s "$tmp" ]] || die "no ed25519 host key from $O_HOST:$port (is sshd reachable and does it offer ed25519?)"
  fp="$(ssh-keygen -lf "$tmp" | awk '{print $2}' | head -n 1)"
  say "$O_HOST:$port offers the host key $fp"
  if [[ -n "$O_FINGERPRINT" ]]; then
    [[ "$O_FINGERPRINT" == "$fp" ]] || die "the fingerprint differs from the one you gave ($O_FINGERPRINT); not pinned. Someone may be in the way."
  elif [[ -t 0 ]]; then
    local answer
    read -r -p "Does that match what 'mirror.sh fingerprint' printed on the survival server? Type yes: " answer
    [[ "$answer" == yes ]] || die "not pinned"
  else
    die "without a terminal pass --fingerprint SHA256:... (read it on the survival server with mirror.sh fingerprint)"
  fi
  run mkdir -p "$SSH_DIR"
  if $DRY_RUN; then echo "[DRY-RUN] pin $fp in $SSH_DIR/known_hosts"; return 0; fi
  install -m 600 "$tmp" "$SSH_DIR/known_hosts"
  say "pinned: the pull will only ever talk to a host with that key"
}

cmd_status() {
  local m
  say "instance:  $INSTANCE_NAME ($SERVER_PATH)"
  say "enabled:   $(cfg_or MIRROR_ENABLED false), role: $(cfg_or MIRROR_ROLE none)"
  case "$(cfg MIRROR_ROLE)" in
    source)
      say "dimensions: $(cfg_or MIRROR_DIMS minecraft/overworld), mode: $(cfg_or MIRROR_SOURCE_MODE live)"
      say "extra folders: $(cfg_or MIRROR_EXTRAS none), mods in snapshots: $(cfg_or MIRROR_EXPORT_MODS true)"
      m="$EXPORT_ROOT/LATEST"
      if [[ -f "$m" ]]; then say "latest snapshot: $(mirror_manifest "$m" snapshot) ($(mirror_manifest "$m" files) files, $(( $(mirror_manifest "$m" bytes) / 1048576 )) MiB)"; else say "latest snapshot: none yet"; fi
      ;;
    target)
      say "source:    $(cfg MIRROR_REMOTE)"
      say "extra folders: $(cfg_or MIRROR_EXTRAS none), run the source mods: $(cfg_or MIRROR_SYNC_MODS false)"
      say "applied:   $(cat "$SYNC_ROOT/APPLIED" 2> /dev/null || echo none)"
      ;;
  esac
  systemctl list-timers --all --no-legend "$INSTANCE_NAME-mirror-*" 2> /dev/null | sed 's/^/timer:     /' || true
}

mirror_manifest() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2> /dev/null; }

DOCTOR_FAIL=0
report() { printf '[%s] %s: %s\n' "$1" "$2" "$3"; [[ "$1" != FAIL ]] || DOCTOR_FAIL=1; }

cmd_doctor() {
  local role age created m unit
  if [[ "$(cfg_or MIRROR_ENABLED false)" != true ]]; then
    report SKIP mirror "not configured for $INSTANCE_NAME"
    return 0
  fi
  role="$(cfg MIRROR_ROLE)"
  report OK mirror "enabled as $role"
  unit="$INSTANCE_NAME-mirror-$([[ "$role" == source ]] && echo export || echo pull).timer"
  if [[ "$(systemctl is-enabled "$unit" 2> /dev/null)" == enabled ]]; then report OK timer "$unit is enabled"; else report FAIL timer "$unit is not enabled; run mirror.sh setup $role again"; fi
  case "$role" in
    source)
      m="$EXPORT_ROOT/LATEST"
      if [[ ! -f "$m" ]]; then
        report WARN snapshot "no snapshot yet (run mirror.sh export once)"
      else
        created="$(mirror_manifest "$m" created_epoch)"
        age=$((($(date +%s) - ${created:-0}) / 3600))
        if ((age > 30)); then report FAIL snapshot "the newest snapshot is ${age}h old; is $unit running?"; else report OK snapshot "newest snapshot is ${age}h old"; fi
      fi
      [[ ! -e "$EXPORT_ROOT/.save-off-active" ]] || report FAIL save-off "a save-off window is marked active; run: bash $MIRROR_HOME/bin/export.sh --scripts-dir $SCRIPTS_DIR --ensure-save-on"
      getent passwd mcsync > /dev/null 2>&1 && report OK account "the read-only account mcsync exists" || report FAIL account "the mcsync account is missing; run mirror.sh setup source"
      ;;
    target)
      [[ -r "$SSH_DIR/id_ed25519" ]] && report OK key "the SSH key exists" || report FAIL key "no SSH key at $SSH_DIR/id_ed25519"
      [[ -s "$SSH_DIR/known_hosts" ]] && report OK host-key "the source's host key is pinned" || report FAIL host-key "no host key is pinned; run mirror.sh pin-host"
      # `sudo -l <command>` answers for that exact command, whatever else the user may do.
      if sudo -n -l "$(command -v systemctl)" stop "$INSTANCE_NAME.service" > /dev/null 2>&1; then report OK sudo "may stop and start $INSTANCE_NAME.service"; else report FAIL sudo "no sudoers rule for stop/start; run mirror.sh setup target"; fi
      if [[ -f "$SYNC_ROOT/APPLIED" ]]; then
        age=$((($(date +%s) - $(stat -c %Y "$SYNC_ROOT/APPLIED")) / 3600))
        if ((age > 30)); then report WARN applied "the last applied snapshot is ${age}h old"; else report OK applied "last applied ${age}h ago ($(cat "$SYNC_ROOT/APPLIED"))"; fi
      else
        report WARN applied "no snapshot applied yet"
      fi
      [[ ! -e "$SYNC_ROOT/cache/.INCOMPLETE" ]] || report WARN cache "the last transfer did not complete; the next run resumes it"
      [[ ! -e "$SYNC_ROOT/SWAP_IN_PROGRESS" ]] || report FAIL swap "a swap was interrupted; run: bash $MIRROR_HOME/bin/pull.sh --scripts-dir $SCRIPTS_DIR --recover"
      [[ -d "$SERVER_PATH/world/dimensions/fabricplots/plots" ]] && report OK plots "the plot dimension exists" || report WARN plots "no plot dimension yet (it appears after the first start with FabricPlots)"
      ;;
    *) report FAIL mirror "MIRROR_ROLE is '$role'; expected source or target" ;;
  esac
  local mods
  mods="$(find "$SERVER_PATH/mods" -maxdepth 1 -type f -name '*.jar' -printf '%f\n' 2> /dev/null | grep -iE 'c2me' | paste -sd ' ' -)" || true
  [[ -z "$mods" ]] || report WARN worldgen "C2ME is installed ($mods); it makes generated chunks differ more between the servers"
  return "$DOCTOR_FAIL"
}

cmd_test() {
  [[ "$(cfg MIRROR_ROLE)" == target ]] || die "mirror.sh test runs on the target (creative) server"
  local remote port key kh out rc fail=0
  remote="$(cfg MIRROR_REMOTE)"
  port="$(cfg_or MIRROR_SSH_PORT 22)"
  key="$SSH_DIR/id_ed25519"
  kh="$SSH_DIR/known_hosts"
  [[ -r "$key" && -s "$kh" ]] || die "pair first: the key and the pinned host key are missing (mirror.sh setup target, pin-host)"
  local opts="-i $key -p $port -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$kh -o ConnectTimeout=15"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ok() { echo "[OK]   $1"; }
  bad() { echo "[FAIL] $1"; fail=1; }

  if rsync -rt -e "ssh $opts" "$remote:/" > "$tmp/list" 2>&1; then ok "the export folder can be listed"; else bad "listing failed: $(head -n 2 "$tmp/list" | tr '\n' ' ')"; fi
  # shellcheck disable=SC2086  # $opts is a list of ssh options
  out="$(timeout 20 ssh -n $opts "$remote" id 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 && "$out" != *uid=* ]]; then ok "a shell command is refused ('id' does not run)"; else bad "'ssh $remote id' ran a command: $out"; fi
  echo probe > "$tmp/probe.txt"
  if rsync -e "ssh $opts" "$tmp/probe.txt" "$remote:/probe.txt" > /dev/null 2>&1; then bad "a write was accepted"; else ok "writes are refused"; fi
  if rsync -e "ssh $opts" -r "$remote:/../" "$tmp/escape" > /dev/null 2>&1; then bad "a path above the export folder was readable"; else ok "paths above the export folder are refused"; fi
  if rsync -e "ssh $opts" -rL "$remote:/" "$tmp/links" > /dev/null 2>&1; then bad "-L (follow links) was accepted"; else ok "following links is refused"; fi
  echo bogus > "$tmp/known_hosts_bogus"
  # shellcheck disable=SC2086
  if timeout 20 ssh -n ${opts/$kh/$tmp/known_hosts_bogus} "$remote" true > /dev/null 2>&1; then bad "a wrong host key was accepted"; else ok "a host key other than the pinned one is refused"; fi
  if rsync -t -e "ssh $opts" "$remote:LATEST" "$tmp/LATEST" > /dev/null 2>&1; then
    ok "a snapshot is published: $(mirror_manifest "$tmp/LATEST" snapshot)"
    echo "       source: mc $(mirror_manifest "$tmp/LATEST" mc_version), loader $(mirror_manifest "$tmp/LATEST" loader), seed $(mirror_manifest "$tmp/LATEST" level_seed)"
    echo "       worldgen mods there: $(mirror_manifest "$tmp/LATEST" worldgen_mods)"
  else
    echo "[WARN] no snapshot published yet (run mirror.sh export on the survival server)"
  fi
  return "$fail"
}

cmd_uninstall() {
  local role
  role="$(cfg MIRROR_ROLE)"
  if $DRY_RUN; then echo "[DRY-RUN] remove the mirror timers, rules and settings of $INSTANCE_NAME"; fi
  if ! $DRY_RUN && [[ -f "$MIRROR_HOME/lib/timer_lib.sh" ]]; then
    (
      export INSTANCE_NAME USER="$RUN_USER"
      source "$MIRROR_HOME/lib/timer_lib.sh"
      timer_remove mirror-export
      timer_remove mirror-pull
    )
  fi
  case "$role" in
    source) root_helper remove-source --export-root "$EXPORT_ROOT" ;;
    target) root_helper remove-target --user "$RUN_USER" --instance "$INSTANCE_NAME" ;;
  esac
  run mirror_config_write "$VARS_FILE"
  if $PURGE; then
    run rm -rf "$STATE"
    say "removed $STATE (snapshots, cache, key and logs)"
  else
    say "kept $STATE (snapshots, cache, key and logs); --purge removes it"
  fi
  say "The world was not touched. The mirror code stays in $MIRROR_HOME until you delete that folder."
}

cmd_prepare() {
  [[ -f "$MIRROR_HOME/prepare.sh" ]] || die "run mirror.sh setup target first"
  local args=(--scripts-dir "$SCRIPTS_DIR")
  [[ -z "$O_SEED" ]] || args+=(--seed "$O_SEED")
  ! $O_FORCE || args+=(--force)
  ! $DRY_RUN || args+=(--dry-run)
  bash "$MIRROR_HOME/prepare.sh" "${args[@]}"
}

case "$COMMAND" in
  setup | prepare | authorize | fingerprint | pin-host | test | export | pull | status | doctor | uninstall) ;;
  *) usage >&2; die "unknown command: $COMMAND" ;;
esac

[[ "$COMMAND" == fingerprint && -z "$SCRIPTS_DIR$INSTANCE_ARG" ]] && { fingerprint_line; exit 0; }
resolve_instance

case "$COMMAND" in
  setup) if [[ "$ROLE_ARG" == source ]]; then cmd_setup_source; else cmd_setup_target; fi ;;
  prepare) cmd_prepare ;;
  authorize) cmd_authorize ;;
  fingerprint) cmd_fingerprint ;;
  pin-host) cmd_pin_host ;;
  test) cmd_test ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  uninstall) cmd_uninstall ;;
  export) exec bash "$MIRROR_HOME/bin/export.sh" --scripts-dir "$SCRIPTS_DIR" "${PASS_ARGS[@]}" ;;
  pull) exec bash "$MIRROR_HOME/bin/pull.sh" --scripts-dir "$SCRIPTS_DIR" "${PASS_ARGS[@]}" ;;
esac
