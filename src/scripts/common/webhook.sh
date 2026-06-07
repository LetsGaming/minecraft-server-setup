#!/bin/bash
# Webhook notification helper
# Sources variables from load_variables.sh and sends notifications
# Usage: source webhook.sh; notify "event_type" "message" ["title"]

# Avoid re-sourcing
if [[ -n "$_WEBHOOK_LOADED" ]]; then return 0 2>/dev/null || true; fi
_WEBHOOK_LOADED=1

_WEBHOOK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load webhook config if not already loaded
if [[ -z "$WEBHOOK_URL" ]]; then
  if [[ -f "$_WEBHOOK_SCRIPT_DIR/variables.txt" ]]; then
    source "$_WEBHOOK_SCRIPT_DIR/variables.txt"
  fi
fi

# Check if an event type should trigger a notification
_event_enabled() {
  local event="$1"
  # If WEBHOOK_EVENTS is not set, all events are enabled
  if [[ -z "$WEBHOOK_EVENTS" ]]; then
    return 0
  fi
  echo "$WEBHOOK_EVENTS" | grep -qw "$event"
}

# Send a webhook notification
# Args: event_type message [title] [color]
#
# JSON is built with jq (--arg / --argjson) rather than heredoc string
# interpolation. Heredoc interpolation embeds shell variables directly into
# the JSON text, so a message containing " or \ produces malformed JSON and
# a crafted player-triggered message could inject arbitrary JSON fields.
# jq escapes all special characters correctly before assembling the payload.
notify() {
  local event="$1"
  local message="$2"
  local title="${3:-$INSTANCE_NAME}"
  local color="${4:-3447003}" # Default: blue

  # Skip if no webhook URL configured
  if [[ -z "$WEBHOOK_URL" || "$WEBHOOK_URL" == "none" ]]; then
    return 0
  fi

  # Skip if this event type is not enabled
  if ! _event_enabled "$event"; then
    return 0
  fi

  # Set color based on event type
  case "$event" in
    *_failed|*_error)   color=15158332 ;; # Red
    *_warning)          color=16776960 ;; # Yellow
    *_complete|*_start) color=3066993  ;; # Green
  esac

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Require jq for safe JSON construction — abort silently if unavailable
  if ! command -v jq &>/dev/null; then
    echo "[webhook] jq not found — notification skipped. Install jq to enable webhooks." >&2
    return 0
  fi

  local payload
  # Detect if it's a Discord webhook
  if [[ "$WEBHOOK_URL" == *"discord.com/api/webhooks"* || "$WEBHOOK_URL" == *"discordapp.com/api/webhooks"* ]]; then
    # Discord embed format — all string values escaped by jq via --arg
    payload=$(jq -nc \
      --arg     title  "$title"     \
      --arg     desc   "$message"   \
      --argjson color  "$color"     \
      --arg     ts     "$timestamp" \
      --arg     footer "$event"     \
      '{embeds:[{title:$title,description:$desc,color:$color,timestamp:$ts,footer:{text:$footer}}]}')
  else
    # Generic webhook JSON
    payload=$(jq -nc \
      --arg     event    "$event"         \
      --arg     instance "$INSTANCE_NAME" \
      --arg     title    "$title"         \
      --arg     message  "$message"       \
      --arg     ts       "$timestamp"     \
      '{event:$event,instance:$instance,title:$title,message:$message,timestamp:$ts}')
  fi

  # Abort if jq produced empty output (should not happen, but be defensive)
  if [[ -z "$payload" ]]; then
    echo "[webhook] Failed to build JSON payload — notification skipped." >&2
    return 0
  fi

  # Send async (don't block the caller)
  curl -s -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$WEBHOOK_URL" &
}

# Convenience wrappers
notify_success() { notify "$1" "$2" "${3:-$INSTANCE_NAME}" 3066993; }
notify_error()   { notify "$1" "$2" "${3:-$INSTANCE_NAME}" 15158332; }
notify_warning() { notify "$1" "$2" "${3:-$INSTANCE_NAME}" 16776960; }
