#!/bin/bash
set -e

set_environment() {
  export USER="$USER"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.. " && pwd)"
export SCRIPT_DIR
  export MAIN_DIR="$HOME"
}
