#!/bin/sh
# shellcheck shell=ash
# Notification dispatcher for Borg Backup events

EVENT_TYPE="${1:-}"      # e.g., backup.success, backup.failure
EVENT_LEVEL="${2:-INFO}" # INFO, WARNING, CRITICAL
EVENT_TITLE="${3:-}"     # Short title
EVENT_MESSAGE="${4:-}"   # Detailed message

# Exit if notifications are not enabled
if [ "$NOTIFY_TRUENAS_ENABLED" != "true" ]; then
    exit 0
fi

# Check if required parameters are provided
if [ -z "$EVENT_TYPE" ] || [ -z "$EVENT_TITLE" ]; then
    echo "ERROR: notify.sh requires EVENT_TYPE and EVENT_TITLE"
    exit 1
fi

# Check if this event should be notified
should_notify() {
    local event_type="$1"

    # If NOTIFY_EVENTS is not set, default to failures only
    if [ -z "$NOTIFY_EVENTS" ]; then
        case "$event_type" in
            *.failure|*.error) return 0 ;;
            *) return 1 ;;
        esac
    fi

    # Check if event type is in the comma-separated list
    echo ",$NOTIFY_EVENTS," | grep -q ",$event_type,"
    return $?
}

# Send notification to TrueNAS API
notify_truenas() {
    local api_url="${NOTIFY_TRUENAS_API_URL}"
    local api_key="${NOTIFY_TRUENAS_API_KEY}"
    local verify_ssl="${NOTIFY_TRUENAS_VERIFY_SSL:-true}"

    # Validate required settings
    if [ -z "$api_url" ] || [ -z "$api_key" ]; then
        echo "WARNING: TrueNAS notifications enabled but API_URL or API_KEY not set"
        return 1
    fi

    # Build curl options
    local curl_opts=""
    if [ "$verify_ssl" = "false" ]; then
        curl_opts="-k"
    fi

    # Build JSON payload
    local json_payload
    json_payload=$(cat <<EOF
{
  "klass": "CustomAlert",
  "args": {
    "title": "$EVENT_TITLE",
    "message": "$EVENT_MESSAGE",
    "level": "$EVENT_LEVEL"
  }
}
EOF
)

    # Send notification
    local response
    response=$(curl -s -w "\n%{http_code}" $curl_opts \
        -X POST "${api_url}/alert/oneshot/create" \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>&1)

    local http_code
    local body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        echo "✓ TrueNAS notification sent: $EVENT_TITLE"
        return 0
    else
        echo "✗ TrueNAS notification failed (HTTP $http_code): $body"
        return 1
    fi
}

# Main notification logic
if ! should_notify "$EVENT_TYPE"; then
    # Event type not configured for notification
    exit 0
fi

# Send to TrueNAS
notify_truenas

# Exit successfully even if notification fails (don't break backups)
exit 0
