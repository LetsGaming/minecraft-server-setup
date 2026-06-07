#!/bin/bash
# validate.sh — prerequisite check for management scripts
# Source this file and call run_validate to verify the environment
# without performing any action.
#
# Usage in a management script:
#   source "$SCRIPT_DIR/common/validate.sh"
#   [[ "$1" == "--validate" ]] && run_validate && exit 0

# Avoid double-sourcing
if [[ -n "$_VALIDATE_LOADED" ]]; then return 0 2>/dev/null || true; fi
_VALIDATE_LOADED=1

run_validate() {
  local errors=0
  local warnings=0

  echo "[validate] Checking management prerequisites..."
  echo

  # 1. variables.txt
  local vars_file="$SCRIPT_DIR/common/variables.txt"
  if [[ -f "$vars_file" ]]; then
    echo "  ✓ variables.txt found"
  else
    echo "  ✗ variables.txt not found at $vars_file"
    echo "    Run setup first, or check that SCRIPT_DIR is correct."
    errors=$((errors + 1))
  fi

  # 2. SERVER_PATH directory
  if [[ -n "$SERVER_PATH" && -d "$SERVER_PATH" ]]; then
    echo "  ✓ SERVER_PATH exists: $SERVER_PATH"
  elif [[ -z "$SERVER_PATH" ]]; then
    echo "  ✗ SERVER_PATH is not set (variables.txt not loaded?)"
    errors=$((errors + 1))
  else
    echo "  ✗ SERVER_PATH does not exist: $SERVER_PATH"
    errors=$((errors + 1))
  fi

  # 3. systemd service
  local service="${TARGET_DIR_NAME:-minecraft}-${INSTANCE_NAME:-server}.service"
  if systemctl list-unit-files "$service" &>/dev/null && \
     systemctl list-unit-files "$service" | grep -q "$service"; then
    local status
    status=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
    echo "  ✓ Service $service found (status: $status)"
  else
    echo "  ~ Service $service not installed (--no-service setup?)"
    warnings=$((warnings + 1))
  fi

  # 4. screen availability
  if command -v screen &>/dev/null; then
    echo "  ✓ screen is available"
  else
    echo "  ✗ screen not found — server control will fail"
    errors=$((errors + 1))
  fi

  # 5. RCON (if enabled)
  if [[ "$USE_RCON" == "true" ]]; then
    if command -v node &>/dev/null; then
      echo "  ✓ RCON enabled, node available"
    else
      echo "  ✗ RCON enabled but node not found"
      errors=$((errors + 1))
    fi
    if [[ -n "$RCON_PASSWORD" ]]; then
      echo "  ✓ RCON_PASSWORD is set"
    else
      echo "  ~ RCON_PASSWORD is empty"
      warnings=$((warnings + 1))
    fi
  else
    echo "  ✓ RCON disabled — using screen"
  fi

  # 6. jq (for webhook)
  if [[ -n "$WEBHOOK_URL" && "$WEBHOOK_URL" != "none" ]]; then
    if command -v jq &>/dev/null; then
      echo "  ✓ jq available (required for webhooks)"
    else
      echo "  ~ jq not found — webhook notifications will be skipped"
      warnings=$((warnings + 1))
    fi
  fi

  echo
  echo "=== Validation result ==="
  if [[ $errors -gt 0 ]]; then
    echo "  ✗ $errors error(s) — management scripts will likely fail"
    return 1
  elif [[ $warnings -gt 0 ]]; then
    echo "  ~ $warnings warning(s) — management scripts should work but check above"
    return 0
  else
    echo "  ✓ All checks passed"
    return 0
  fi
}
