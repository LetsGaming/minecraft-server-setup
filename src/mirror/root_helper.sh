#!/bin/bash
# The mirror's privileged steps, run through `sudo bash root_helper.sh <action>` by
# mirror.sh (which itself runs as the server owner). Everything else the mirror
# does needs no privileges.
#
#   source-account  --user U --export-root DIR   shell-less rrsync account `mcsync`,
#                                                export folder, sshd drop-in
#   authorize       --export-root DIR --from ADDR --key "ssh-ed25519 ..."
#                                                a root-owned, pinned authorized_keys line
#   target-sudoers  --user U --instance N        sudoers rule: start/stop N.service only
#   remove-source   --export-root DIR            drop this export's key lines (and the
#                                                account when none are left)
#   remove-target   --user U --instance N        drop the sudoers rule
#   print-sudoers   --user U --instance N        print the rule, change nothing
#
# Every action accepts --dry-run, which prints what it would do. All inputs are
# validated against strict patterns: they end up in sshd and sudoers files.
#
# Test hooks: MC_MIRROR_TEST=1 skips the root check, chown and service calls;
# MC_MIRROR_ETC replaces /etc.
set -euo pipefail

ACCOUNT=mcsync
ETC="${MC_MIRROR_ETC:-/etc}"
TEST_MODE="${MC_MIRROR_TEST:-0}"
DRY_RUN=false

ACTION="${1:-}"
[[ -n "$ACTION" ]] || { sed -n '2,20p' "${BASH_SOURCE[0]}" >&2; exit 2; }
shift

USER_NAME="" EXPORT_ROOT="" FROM="" KEY="" INSTANCE=""
while (($#)); do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --export-root) EXPORT_ROOT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --instance) INSTANCE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { echo "[mirror] $*"; }
fail() { echo "[mirror] ERROR: $*" >&2; exit 1; }

if [[ "$TEST_MODE" != 1 && "$DRY_RUN" != true && "$(id -u)" != 0 ]]; then
  fail "run this through sudo (it changes accounts, sshd and sudoers)"
fi

# run <command...>: the command, or a line saying what it would do.
run() {
  if $DRY_RUN; then echo "[DRY-RUN] $*"; else "$@"; fi
}

# write_file <path> <mode> <owner:group>   (content on stdin)
write_file() {
  local path="$1" mode="$2" owner="$3" tmp
  if $DRY_RUN; then
    echo "[DRY-RUN] write $path (mode $mode, owner $owner):"
    sed 's/^/[DRY-RUN]   | /'
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "$path.XXXXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  [[ "$TEST_MODE" == 1 ]] || chown "$owner" "$tmp"
  mv -f -- "$tmp" "$path"
}

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_instance() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
# Absolute, no spaces, quotes, $, backticks or backslashes: the path is embedded
# in the forced command of an authorized_keys line.
valid_path() { [[ "$1" =~ ^/[A-Za-z0-9_./-]+$ && "$1" != *..* ]]; }
valid_key() { [[ "$1" =~ ^ssh-ed25519\ AAAA[0-9A-Za-z+/]+={0,2}(\ [A-Za-z0-9@._-]+)?$ ]]; }
# An address, a CIDR, a host name or a pattern list; no quote or space can end up
# inside the from="..." option.
valid_from() { [[ "$1" =~ ^[0-9A-Za-z.:,*?!/-]{1,200}$ ]]; }

rrsync_path() {
  local p
  p="$(command -v rrsync 2> /dev/null || true)"
  [[ -n "$p" ]] || { [[ -x /usr/share/doc/rsync/scripts/rrsync ]] && p=/usr/share/doc/rsync/scripts/rrsync; }
  [[ -n "$p" ]] || fail "rrsync is not installed (it ships with the rsync package on Debian 12 and newer)"
  printf '%s\n' "$p"
}

sshd_drop_in() { printf '%s\n' "$ETC/ssh/sshd_config.d/50-mcsync.conf"; }
keys_file() { printf '%s\n' "$ETC/ssh/mcsync/authorized_keys"; }

ensure_ancestors_traversable() {
  local dir
  dir="$(dirname "$1")"
  while [[ "$dir" != "/" && "$dir" != "." ]]; do
    # Others may not enter the folder: give the account search permission only.
    if [[ "$(stat -c %A "$dir" 2> /dev/null | cut -c10)" != x ]]; then
      command -v setfacl > /dev/null 2>&1 || fail "setfacl is missing (install the acl package) and $dir is not searchable by the $ACCOUNT account"
      run setfacl -m "u:$ACCOUNT:--x" "$dir"
    fi
    dir="$(dirname "$dir")"
  done
}

do_source_account() {
  valid_user "$USER_NAME" || fail "--user is not a valid user name"
  valid_path "$EXPORT_ROOT" || fail "--export-root must be an absolute path of plain characters"
  if [[ "$TEST_MODE" != 1 ]]; then
    id -u "$USER_NAME" > /dev/null 2>&1 || fail "user $USER_NAME does not exist"
    command -v sshd > /dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || fail "OpenSSH server is not installed (apt install openssh-server)"
  fi
  rrsync_path > /dev/null

  # The account runs only the forced rrsync command, but sshd starts that through
  # the account's shell, and rrsync's own man page warns that bash may read rc
  # files first, so it gets /bin/sh and no password.
  if ! getent passwd "$ACCOUNT" > /dev/null 2>&1; then
    run useradd --system --create-home --home-dir "/var/lib/$ACCOUNT" --shell /bin/sh "$ACCOUNT"
  fi
  # The export job (the server user) creates directories below the export root;
  # without membership in the group the kernel drops the setgid bit.
  run usermod -aG "$ACCOUNT" "$USER_NAME"

  run mkdir -p "$EXPORT_ROOT"
  run chown "$USER_NAME:$ACCOUNT" "$EXPORT_ROOT"
  run chmod 2750 "$EXPORT_ROOT"
  ensure_ancestors_traversable "$EXPORT_ROOT"

  run mkdir -p "$ETC/ssh/mcsync"
  run chmod 755 "$ETC/ssh/mcsync"
  if $DRY_RUN || [[ ! -f "$(keys_file)" ]]; then
    : | write_file "$(keys_file)" 644 root:root
  fi

  local drop_in
  drop_in="$(sshd_drop_in)"
  if [[ "$TEST_MODE" != 1 ]] && ! grep -rqE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$ETC/ssh/sshd_config" 2> /dev/null; then
    say "sshd_config does not include $ETC/ssh/sshd_config.d/; add this block to it by hand:"
    mirror_sshd_block
    return 3
  fi
  mirror_sshd_block | write_file "$drop_in" 644 root:root
  if [[ "$TEST_MODE" != 1 ]]; then
    run sshd -t
    run systemctl reload ssh 2> /dev/null || run systemctl reload sshd
  fi
  say "account $ACCOUNT is ready; the export folder is $EXPORT_ROOT"
}

mirror_sshd_block() {
  cat <<'CFG'
# Managed by the mirror: the read-only account that serves the export folder.
Match User mcsync
    AuthorizedKeysFile /etc/ssh/mcsync/authorized_keys
    AuthenticationMethods publickey
    PasswordAuthentication no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
CFG
}

do_authorize() {
  valid_path "$EXPORT_ROOT" || fail "--export-root must be an absolute path of plain characters"
  valid_from "$FROM" || fail "--from must be an address, a CIDR or a host name"
  valid_key "$KEY" || fail "--key must be one ssh-ed25519 public key on a single line"
  local rrsync blob line file tmp
  rrsync="$(rrsync_path)"
  file="$(keys_file)"
  blob="$(awk '{print $2}' <<< "$KEY")"
  # Read-only rrsync pinned to the export folder and to the target's address;
  # restrict turns off forwarding, a terminal and rc files.
  line="restrict,from=\"$FROM\",command=\"nice -n 19 ionice -c3 $rrsync -ro $EXPORT_ROOT\" $KEY"
  if $DRY_RUN; then
    echo "[DRY-RUN] authorized_keys line for $file:"
    echo "[DRY-RUN]   | $line"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  chmod 755 "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  # A key that is already listed is replaced, so its address can be changed.
  { [[ -f "$file" ]] && grep -vF -- " $blob" "$file" || true; printf '%s\n' "$line"; } > "$tmp"
  chmod 644 "$tmp"
  [[ "$TEST_MODE" == 1 ]] || chown root:root "$tmp"
  mv -f -- "$tmp" "$file"
  say "the key is authorized for $FROM, read-only, for $EXPORT_ROOT"
}

sudoers_alias() { printf 'MC_MIRROR_%s\n' "$(tr 'a-z-' 'A-Z_' <<< "$1")"; }

sudoers_content() {
  local systemctl alias
  systemctl="$(command -v systemctl 2> /dev/null || echo /usr/bin/systemctl)"
  alias="$(sudoers_alias "$INSTANCE")"
  cat <<RULE
# Managed by the mirror: lets $USER_NAME stop and start the creative server for the
# nightly swap. Nothing else.
Cmnd_Alias $alias = $systemctl start $INSTANCE.service, $systemctl stop $INSTANCE.service
$USER_NAME ALL=(root) NOPASSWD: $alias
RULE
}

do_target_sudoers() {
  valid_user "$USER_NAME" || fail "--user is not a valid user name"
  valid_instance "$INSTANCE" || fail "--instance is not a valid instance name"
  local dest="$ETC/sudoers.d/mc-mirror-$USER_NAME-$INSTANCE" tmp
  if $DRY_RUN; then
    sudoers_content | write_file "$dest" 0440 root:root
    return 0
  fi
  mkdir -p "$ETC/sudoers.d"
  tmp="$(mktemp)"
  sudoers_content > "$tmp"
  if command -v visudo > /dev/null 2>&1; then
    visudo -cf "$tmp" > /dev/null || { rm -f "$tmp"; fail "the generated sudoers rule did not validate"; }
  fi
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    say "the sudoers rule is already in place"
    return 0
  fi
  chmod 0440 "$tmp"
  [[ "$TEST_MODE" == 1 ]] || chown root:root "$tmp"
  mv -f -- "$tmp" "$dest"
  say "$USER_NAME may start and stop $INSTANCE.service without a password (and nothing else)"
}

do_remove_source() {
  valid_path "$EXPORT_ROOT" || fail "--export-root must be an absolute path of plain characters"
  local file left
  file="$(keys_file)"
  if [[ -f "$file" ]]; then
    if $DRY_RUN; then
      echo "[DRY-RUN] drop the key lines for $EXPORT_ROOT from $file"
    else
      grep -vF -- "-ro $EXPORT_ROOT\"" "$file" > "$file.new" || true
      mv -f -- "$file.new" "$file"
      chmod 644 "$file"
    fi
  fi
  left="$(grep -c 'ssh-ed25519' "$file" 2> /dev/null || true)"
  if [[ "${left:-0}" == 0 ]]; then
    run rm -f "$(sshd_drop_in)" "$file"
    if [[ "$TEST_MODE" != 1 ]]; then
      run systemctl reload ssh 2> /dev/null || run systemctl reload sshd || true
      if getent passwd "$ACCOUNT" > /dev/null 2>&1; then run userdel -r "$ACCOUNT" || true; fi
    fi
    say "no key is left: the $ACCOUNT account and its sshd block are removed"
  else
    say "other exports still use the $ACCOUNT account; it stays"
  fi
}

do_remove_target() {
  valid_user "$USER_NAME" || fail "--user is not a valid user name"
  valid_instance "$INSTANCE" || fail "--instance is not a valid instance name"
  run rm -f "$ETC/sudoers.d/mc-mirror-$USER_NAME-$INSTANCE"
}

case "$ACTION" in
  source-account) do_source_account ;;
  authorize) do_authorize ;;
  target-sudoers) do_target_sudoers ;;
  remove-source) do_remove_source ;;
  remove-target) do_remove_target ;;
  print-sudoers)
    valid_user "$USER_NAME" || fail "--user is not a valid user name"
    valid_instance "$INSTANCE" || fail "--instance is not a valid instance name"
    sudoers_content
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
