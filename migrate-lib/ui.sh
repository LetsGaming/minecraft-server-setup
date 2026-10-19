#!/bin/bash
# Terminal colors, message helpers and the dry-run command wrapper.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.

# ── Colors ──
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "    $*"; }

# Defined here (not further down) so the helpers below can use it.
run_cmd() {
  $DRY_RUN && echo "[DRY-RUN] $*" || "$@"
}
