#!/bin/bash
# Gives the API wrapper its own Linux user: it can read the server's files, write
# the few it edits itself, and run exactly the scripts it needs as the server
# user. Nothing else. Run as root, once per instance, safe to run again:
#
#   sudo bash service_user.sh --scripts-dir <base>/scripts/<instance> [--user mcapi]
#   sudo bash service_user.sh --scripts-dir ... --dry-run     # print, change nothing
#   sudo bash service_user.sh --scripts-dir ... --print-sudoers
#
# What it does, in order (see docs/service-user.md for the reasoning):
#   1. creates the system user (no login shell, no home) when missing
#   2. grants it, with POSIX ACLs, read on the instance, scripts, backups and the
#      wrapper's own folder; write only on the config folders, server.properties,
#      the config snapshot folder, world/stats and the backups folder; and
#      traverse (x) on the folders above them. Ownership is never changed.
#   3. sets UMask=0002 in the instance's systemd unit, so files the server creates
#      keep the write bit the ACL mask needs (the server's group has one member)
#   4. writes /etc/sudoers.d/mc-service-<user>-<instance>, checked with visudo -c
#      before it is installed
#
# Exit: 0 done (or nothing to do), 1 failed, 2 usage, 3 a manual step is needed.

set -euo pipefail

SU_USER="mcapi"
SU_SCRIPTS_DIR=""
SU_DRY_RUN=false
SU_PRINT_SUDOERS=false
SU_UNIT_DIR="${SU_UNIT_DIR:-/etc/systemd/system}"
SU_SUDOERS_DIR="${SU_SUDOERS_DIR:-/etc/sudoers.d}"
SU_BASH_PATH=""
SU_NODE_PATH=""
SU_SCREEN_PATH=""
SU_SYSTEMCTL_PATH=""

# Configuration folders the wrapper's editor may write, relative to the server folder.
# Not plugins/ (S-004): a jar dropped there is code the server runs as its owner
# at the next start. Plugin configs stay readable; editing them through the
# dashboard needs the wrapper to run as the server user.
SU_CONFIG_ROOTS=(config defaultconfigs world/serverconfig)
SU_SNAPSHOT_DIR=".mcbot-config-snapshots"

su_usage() {
  sed -n '2,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

su_say() { echo "[service-user] $*"; }
su_die() { echo "[service-user] $*" >&2; exit "${2:-1}"; }

# Every change goes through here, so a dry run prints exactly what would happen.
su_run() {
  if [[ "$SU_DRY_RUN" == true ]]; then
    echo "  would run: $*"
    return 0
  fi
  "$@"
}

# A level-name that is one plain folder name: no separator, no "..", no leading
# dot or dash.
su_valid_level() {
  local re='^[A-Za-z0-9_][A-Za-z0-9._ -]{0,63}$'
  [[ "$1" =~ $re && "$1" != *..* ]]
}

su_valid_name() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

# A path that sudoers and a shell can both take literally: no space, quote, comma,
# colon, equals, backslash or wildcard.
su_safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/+-]+$ ]]; }

su_resolve_tool() { # name override -> absolute path
  local found="$2"
  [[ -n "$found" ]] || found="$(command -v "$1" 2> /dev/null || true)"
  [[ "$found" == /* ]] || su_die "Cannot find $1; pass --$1-path with an absolute path." 2
  su_safe_path "$found" || su_die "The path of $1 has characters sudoers cannot take literally: $found" 2
  echo "$found"
}

# A value out of the deployed variables.txt (KEY="value"), read as data: this
# runs as root and must not source a file the server user can write. Setup
# escapes \ " $ and ` inside the quotes; undo exactly that (S-030), where the
# old pattern cut the value at its first escaped quote.
su_var() {
  local line value
  line="$(grep -m 1 "^$1=" "$SU_SCRIPTS_DIR/common/variables.txt" || true)"
  [[ -n "$line" ]] || return 0
  value="${line#*=}"
  if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
    value="${value:1:${#value}-2}"
    value="$(printf '%s' "$value" | sed -e 's/\\\(["$`\\]\)/\1/g')"
  fi
  printf '%s\n' "$value"
}

# The sudoers file for one instance. Pure: prints it, touches nothing.
# Args: service-user server-user instance scripts-dir backups-dir
#
# S-005: alias names must be upper case (visudo rejects MCS_testinst_UNIT), and
# a rule that names arguments matches only those arguments: "bash restore.sh"
# allows restore.sh with none at all. Each script is listed with the argument
# shapes the API wrapper really uses, and no more:
#   - the scripts/run actions take no arguments; backup also takes --archive
#   - restore takes the archive the wrapper resolved: --file <backups>/... --y
#   - upgrade, prune and the mod scripts take their flags and a slug
# A "*" here also matches spaces; it is only used where the script itself
# validates what follows (restore refuses archives outside the backups folder
# and archives this user did not make).
su_sudoers_content() {
  local svc="$1" owner="$2" inst="$3" sd="$4" bk="$5"
  local id="${inst//[^A-Za-z0-9]/_}"
  id="${id^^}"
  local b="$SU_BASH_PATH" n="$SU_NODE_PATH" s="$SU_SCREEN_PATH" c="$SU_SYSTEMCTL_PATH"
  cat << EOF
# Written by service_user.sh for the API wrapper's user '$svc'. Do not edit by hand:
# run service_user.sh again instead. Scripts below are owned by '$owner' and must
# stay unwritable by '$svc', or this grant would let it run any code as '$owner'.

Cmnd_Alias MCS_${id}_UNIT = \\
    $c start $inst.service, \\
    $c stop $inst.service, \\
    $c restart $inst.service, \\
    $c status $inst.service, \\
    $c reset-failed $inst.service, \\
    $c show $inst.service *

Cmnd_Alias MCS_${id}_SCRIPTS = \\
    $b $sd/start.sh, \\
    $b $sd/shutdown.sh, \\
    $b $sd/smart_restart.sh, \\
    $b $sd/misc/status.sh, \\
    $b $sd/rollback.sh, \\
    $b $sd/rollback.sh --y, \\
    $b $sd/backup/backup.sh, \\
    $b $sd/backup/backup.sh --archive, \\
    $b $sd/backup/restore.sh --file $bk/* --y, \\
    $b $sd/backup/restore.sh --y --archive --file $bk/*, \\
    $b $sd/update/upgrade.sh *, \\
    $n $sd/world/prune-chunks.js *, \\
    $n $sd/update/add-mod.js *, \\
    $n $sd/update/remove-mod.js *, \\
    $n $sd/update/update-mod.js *, \\
    $n $sd/update/update-mods.js *, \\
    $n $sd/update/check-updates.js *, \\
    $n $sd/update/toggle-mod.js *

Cmnd_Alias MCS_${id}_SCREEN = \\
    $s -list, \\
    $s -S $inst -X stuff *

$svc ALL=(root) NOPASSWD: MCS_${id}_UNIT
$svc ALL=($owner) NOPASSWD: MCS_${id}_SCRIPTS, MCS_${id}_SCREEN
EOF
}

# True when <target> lies under <root>, no path component below <root> is a
# symlink, and its resolved location is still under the resolved <root>. The
# server user owns these trees and can swap any entry for a symlink.
su_contained() {
  local root="${1%/}" target="${2%/}" rel segment cur real_root real
  [[ "$target" == "$root" || "$target" == "$root"/* ]] || return 1
  rel="${target#"$root"}"
  cur="$root"
  while [[ -n "$rel" ]]; do
    rel="${rel#/}"
    segment="${rel%%/*}"
    [[ -n "$segment" ]] || break
    [[ "$segment" != . && "$segment" != .. ]] || return 1
    cur="$cur/$segment"
    [[ ! -L "$cur" ]] || return 1
    if [[ "$rel" == */* ]]; then rel="/${rel#*/}"; else rel=""; fi
  done
  real_root="$(realpath -e -- "$root" 2> /dev/null)" || return 1
  real="$(realpath -e -- "$target" 2> /dev/null)" || return 1
  [[ "$real" == "$real_root" || "$real" == "$real_root"/* ]]
}

SU_REFUSED=0

# setfacl calls for one path. Args: mode(r|rw) recursive(yes|no) path root
# Never follows a symlink: the path must stay inside <root> (su_contained) and
# setfacl runs with -P, so links met while recursing are skipped.
su_acl() {
  local mode="$1" recursive="$2" target="$3" root="$4"
  local perm="rX"
  [[ "$mode" == rw ]] && perm="rwX"
  [[ -e "$target" || -L "$target" ]] || return 0
  if ! su_contained "$root" "$target"; then
    su_say "Refusing $target: it is a symlink or leads outside $root."
    SU_REFUSED=$((SU_REFUSED + 1))
    return 0
  fi
  if [[ "$recursive" == yes ]]; then
    su_run setfacl -R -P -m "u:$SU_USER:$perm" "$target"
    [[ -d "$target" ]] && su_run setfacl -R -P -d -m "u:$SU_USER:$perm" "$target"
  else
    su_run setfacl -P -m "u:$SU_USER:$perm" "$target"
  fi
  return 0
}

# x on every folder from the install root up, so the user can reach what it may read.
su_traverse() {
  local dir
  dir="$(realpath -e -- "$1" 2> /dev/null)" || return 0
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    su_run setfacl -P -m "u:$SU_USER:x" "$dir"
    dir="$(dirname "$dir")"
  done
}

su_ensure_user() {
  if id -u "$SU_USER" > /dev/null 2>&1; then
    su_say "User $SU_USER exists."
    return 0
  fi
  su_say "Creating system user $SU_USER."
  su_run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SU_USER"
}

su_apply_acls() {
  local server_dir="$1" backups_dir="$2" scripts_dir="$3" api_dir="$4" base="$5"

  su_traverse "$base"
  [[ -n "$backups_dir" && "$backups_dir" != none ]] && su_traverse "$backups_dir"

  su_acl r yes "$server_dir" "$server_dir"
  su_acl r yes "$scripts_dir" "$scripts_dir"
  su_acl r yes "$api_dir" "$api_dir"

  # What the wrapper writes itself.
  local root
  for root in "${SU_CONFIG_ROOTS[@]}"; do
    su_acl rw yes "$server_dir/$root" "$server_dir"
  done
  su_acl rw no "$server_dir/server.properties" "$server_dir"
  if [[ ! -d "$server_dir/$SU_SNAPSHOT_DIR" ]]; then
    su_run install -d -m 0750 -o "$SU_OWNER" "$server_dir/$SU_SNAPSHOT_DIR"
  fi
  su_acl rw yes "$server_dir/$SU_SNAPSHOT_DIR" "$server_dir"
  if su_valid_level "$SU_LEVEL"; then
    su_acl rw yes "$server_dir/$SU_LEVEL/stats" "$server_dir"
  else
    su_say "Not granting write on the stats folder: level-name '$SU_LEVEL' is not a plain folder name."
  fi
  # The wrapper's own config holds its API key; a later chmod 600 would zero the ACL mask.
  su_acl r no "$api_dir/api-server-config.json" "$api_dir"
  if [[ -n "$backups_dir" && "$backups_dir" != none ]]; then
    su_acl r yes "$backups_dir" "$backups_dir"
    # Deleting an archive needs write on the folder that holds it, not on the file.
    su_run find "$backups_dir" -type d -exec setfacl -P -m "u:$SU_USER:rwx" {} +
    su_run setfacl -P -d -m "u:$SU_USER:rwx" "$backups_dir"
  fi
}

# UMask=0002 in the instance unit, so new files keep the write bit the ACL mask needs.
su_patch_unit() {
  local unit="$SU_UNIT_DIR/$SU_INSTANCE.service"
  if [[ ! -f "$unit" ]]; then
    su_say "No unit at $unit; not setting UMask."
    return 0
  fi
  if grep -q '^UMask=' "$unit"; then
    su_say "The unit already sets UMask."
    return 0
  fi
  su_say "Adding UMask=0002 to $unit (takes effect at the next server restart)."
  local tmp
  tmp="$(mktemp)"
  awk '{ print } /^\[Service\]/ && !done { print "UMask=0002"; done = 1 }' "$unit" > "$tmp"
  if [[ "$SU_DRY_RUN" == true ]]; then
    echo "  would replace $unit with a copy that has UMask=0002"
    rm -f "$tmp"
    return 0
  fi
  cp -p "$unit" "$unit.pre-service-user"
  cat "$tmp" > "$unit"
  rm -f "$tmp"
  systemctl daemon-reload || su_say "daemon-reload failed; run it by hand."
}

su_install_sudoers() {
  local file="$SU_SUDOERS_DIR/mc-service-$SU_USER-$SU_INSTANCE"
  local tmp
  tmp="$(mktemp)"
  su_sudoers_content "$SU_USER" "$SU_OWNER" "$SU_INSTANCE" "$SU_SCRIPTS_DIR" "$SU_BACKUPS_DIR" > "$tmp"
  if ! visudo -cf "$tmp" > /dev/null; then
    rm -f "$tmp"
    su_die "The generated sudoers rules do not parse; nothing was installed." 1
  fi
  if [[ "$SU_DRY_RUN" == true ]]; then
    echo "  would install $file:"
    sed 's/^/    | /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    su_say "Sudoers rules are current."
    rm -f "$tmp"
    return 0
  fi
  install -m 0440 -o root -g root "$tmp" "$file"
  rm -f "$tmp"
  su_say "Installed $file."
}

su_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) SU_USER="${2:-}"; shift 2 ;;
      --scripts-dir) SU_SCRIPTS_DIR="${2:-}"; shift 2 ;;
      --bash-path) SU_BASH_PATH="${2:-}"; shift 2 ;;
      --node-path) SU_NODE_PATH="${2:-}"; shift 2 ;;
      --screen-path) SU_SCREEN_PATH="${2:-}"; shift 2 ;;
      --systemctl-path) SU_SYSTEMCTL_PATH="${2:-}"; shift 2 ;;
      --dry-run) SU_DRY_RUN=true; shift ;;
      --print-sudoers) SU_PRINT_SUDOERS=true; shift ;;
      -h | --help) su_usage; exit 0 ;;
      *) su_usage >&2; exit 2 ;;
    esac
  done

  [[ -n "$SU_SCRIPTS_DIR" && -f "$SU_SCRIPTS_DIR/common/variables.txt" ]] ||
    su_die "--scripts-dir must be the deployed scripts folder (it holds common/variables.txt)." 2
  SU_SCRIPTS_DIR="$(cd "$SU_SCRIPTS_DIR" && pwd)"
  su_valid_name "$SU_USER" || su_die "'$SU_USER' is not a valid user name." 2
  su_safe_path "$SU_SCRIPTS_DIR" || su_die "The scripts path has characters sudoers cannot take literally." 2

  SU_OWNER="$(su_var USER)"
  SU_INSTANCE="$(su_var INSTANCE_NAME)"
  local server_dir backups_dir
  server_dir="$(su_var SERVER_PATH)"
  backups_dir="$(su_var BACKUPS_PATH)"
  [[ -n "$SU_OWNER" && -n "$SU_INSTANCE" && -n "$server_dir" ]] || su_die "variables.txt lacks USER, INSTANCE_NAME or SERVER_PATH." 1
  su_valid_name "$SU_OWNER" || su_die "The server user '$SU_OWNER' is not a valid user name." 1
  [[ "$SU_USER" != "$SU_OWNER" && "$SU_USER" != root ]] || su_die "The service user must be neither root nor the server user." 2
  su_safe_path "$server_dir" || su_die "The server path has characters sudoers cannot take literally." 2
  [[ -n "$backups_dir" && "$backups_dir" != none ]] || su_die "variables.txt lacks BACKUPS_PATH." 1
  su_safe_path "$backups_dir" || su_die "The backups path has characters sudoers cannot take literally." 2
  SU_BACKUPS_DIR="$backups_dir"

  SU_BASH_PATH="$(su_resolve_tool bash "$SU_BASH_PATH")"
  SU_NODE_PATH="$(su_resolve_tool node "$SU_NODE_PATH")"
  SU_SCREEN_PATH="$(su_resolve_tool screen "$SU_SCREEN_PATH")"
  SU_SYSTEMCTL_PATH="$(su_resolve_tool systemctl "$SU_SYSTEMCTL_PATH")"

  if [[ "$SU_PRINT_SUDOERS" == true ]]; then
    su_sudoers_content "$SU_USER" "$SU_OWNER" "$SU_INSTANCE" "$SU_SCRIPTS_DIR" "$SU_BACKUPS_DIR"
    return 0
  fi

  if [[ "$SU_DRY_RUN" != true ]]; then
    [[ "$(id -u)" == 0 ]] || su_die "Run this as root (sudo)." 2
    command -v setfacl > /dev/null 2>&1 || su_die "setfacl is missing. Install it (apt install acl) and run this again." 3
  fi

  # <base>/scripts/<instance>  ->  <base>
  local base api_dir
  base="$(dirname "$(dirname "$SU_SCRIPTS_DIR")")"
  api_dir="$base/services/api-server"
  SU_LEVEL="$(sed -n 's/^level-name=//p' "$server_dir/server.properties" 2> /dev/null | head -n 1 | tr -d '\r')"
  SU_LEVEL="${SU_LEVEL:-world}"

  su_ensure_user
  su_apply_acls "$server_dir" "$backups_dir" "$SU_SCRIPTS_DIR" "$api_dir" "$base"
  su_patch_unit
  su_install_sudoers
  if [[ "$SU_REFUSED" -gt 0 ]]; then
    su_die "$SU_REFUSED path(s) were skipped because they are symlinks or leave the instance folders. Check them (a mod may have planted them), then run this again." 1
  fi

  su_say "Done. Point the wrapper's unit at User=$SU_USER (create_api_server_service.js does this when API_SERVER.SERVICE_USER is set)."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  su_main "$@"
fi
