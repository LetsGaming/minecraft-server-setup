#!/bin/bash
set -e

set_environment() {
  export USER="$USER"
  export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export MAIN_DIR="$HOME"
}
