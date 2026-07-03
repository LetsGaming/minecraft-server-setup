#!/usr/bin/env bash

set -euo pipefail

# SEC-02: install Jabba without piping remote content straight into a shell.
# We download the installer to a temp file, verify its SHA-256 against a pinned
# value, and only then execute it. A truncated download or a tampered/MITM'd
# script fails closed instead of running.
#
# The pinned hash is for Jabba-Team/jabba (the maintained fork) main/install.sh.
# When bumping JABBA_VERSION or the installer, recompute and update the hash:
#   curl -fsSL <installer-url> | sha256sum
# or override at runtime without editing this file:
#   JABBA_INSTALL_SHA256=<hash> bash install_jabba.sh

JABBA_VERSION="${JABBA_VERSION:-0.14.0}"
export JABBA_HOME="$HOME/.jabba"
export PATH="$JABBA_HOME/bin:$PATH"

JABBA_INSTALL_URL="${JABBA_INSTALL_URL:-https://raw.githubusercontent.com/Jabba-Team/jabba/main/install.sh}"
JABBA_INSTALL_SHA256="${JABBA_INSTALL_SHA256:-7298872bae6a19bf22b36c302cb260e6fa88cc09ee21d50cdd0755b4270a9e5e}"

# Check if jabba is installed
if command -v jabba &> /dev/null; then
  echo "Jabba is already installed."
else
  echo "Jabba not found. Installing Jabba v$JABBA_VERSION..."

  tmp_installer="$(mktemp "${TMPDIR:-/tmp}/jabba-install.XXXXXX.sh")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_installer'" EXIT

  if ! curl -fsSL --proto '=https' --tlsv1.2 "$JABBA_INSTALL_URL" -o "$tmp_installer"; then
    echo "[install_jabba] ERROR: failed to download installer from $JABBA_INSTALL_URL" >&2
    exit 1
  fi

  actual_sha="$(sha256sum "$tmp_installer" | awk '{print $1}')"
  if [ "$actual_sha" != "$JABBA_INSTALL_SHA256" ]; then
    echo "[install_jabba] ERROR: installer checksum mismatch — refusing to run." >&2
    echo "  expected: $JABBA_INSTALL_SHA256" >&2
    echo "  actual:   $actual_sha" >&2
    echo "  If you intentionally bumped the Jabba installer, update the pinned" >&2
    echo "  hash in install_jabba.sh (or set JABBA_INSTALL_SHA256)." >&2
    exit 1
  fi

  echo "[install_jabba] checksum OK — running verified installer."
  bash "$tmp_installer"
fi

# Source Jabba into the shell if not already available
if [ -f "$JABBA_HOME/jabba.sh" ]; then
  # shellcheck disable=SC1091
  . "$JABBA_HOME/jabba.sh"
  export PATH="$JABBA_HOME/bin:$PATH"
  echo "Jabba sourced."
else
  echo "Jabba not found. Aborting."
  exit 1
fi
