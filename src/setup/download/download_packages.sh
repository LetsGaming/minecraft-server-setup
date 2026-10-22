#!/bin/bash
set -e

HERE="${BASH_SOURCE[0]%/*}"
[ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
SCRIPT_DIR="${SCRIPT_DIR:-$HERE/../../..}"
source "$HERE/../../common/prereqs.sh"

ensure_prerequisites power
