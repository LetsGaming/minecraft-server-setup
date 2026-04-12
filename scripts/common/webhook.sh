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
    *_failed|*_error)  color=15158332 ;; # Red
    *_warning)         color=16776960 ;; # Yellow
    *_complete|*_start) color=3066993 ;; # Green
  esac

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Detect if it's a Discord webhook
  if [[ "$WEBHOOK_URL" == *"discord.com/api/webhooks"* || "$WEBHOOK_URL" == *"discordapp.com/api/webhooks"* ]]; then
    # Discord embed format
    local payload
    payload=$(cat <<EOJSON
{
  "embeds": [{
    "title": "$title",
    "description": "$message",
    "color": $color,
    "timestamp": "$timestamp",
    "footer": {"text": "$event"}
  }]
}
EOJSON
)
  else
    # Generic webhook JSON
    local payload
    payload=$(cat <<EOJSON
{
  "event": "$event",
  "instance": "$INSTANCE_NAME",
  "title": "$title",
  "message": "$message",
  "timestamp": "$timestamp"
}
EOJSON
)
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
