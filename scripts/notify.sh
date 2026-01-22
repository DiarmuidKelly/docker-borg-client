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

# Send notification to TrueNAS API via WebSocket JSON-RPC
notify_truenas() {
    local api_url="${NOTIFY_TRUENAS_API_URL}"
    local api_key="${NOTIFY_TRUENAS_API_KEY}"
    local verify_ssl="${NOTIFY_TRUENAS_VERIFY_SSL:-true}"

    # Validate required settings
    if [ -z "$api_url" ] || [ -z "$api_key" ]; then
        echo "WARNING: TrueNAS notifications enabled but API_URL or API_KEY not set"
        return 1
    fi

    # Ensure /api/current endpoint (strip trailing slash first)
    local ws_url
    ws_url=$(echo "$api_url" | sed 's|/$||')
    ws_url="${ws_url}/api/current"

    # Escape JSON strings (basic escaping for quotes and newlines)
    local escaped_title escaped_message
    escaped_title=$(echo "$EVENT_TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
    escaped_message=$(echo "$EVENT_MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')

    # Build JSON-RPC 2.0 payload for alert.oneshot_create
    local json_payload
    json_payload=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"alert.oneshot_create","params":["BorgBackupAlert",{"title":"$escaped_title","message":"$escaped_message","level":"$EVENT_LEVEL"}]}
EOF
)

    # Send notification via WebSocket
    local response
    if [ "$verify_ssl" = "false" ]; then
        response=$(echo "$json_payload" | websocat --text --one-message --jsonrpc \
            --header="Authorization: Bearer ${api_key}" \
            --insecure \
            "$ws_url" 2>&1)
    else
        response=$(echo "$json_payload" | websocat --text --one-message --jsonrpc \
            --header="Authorization: Bearer ${api_key}" \
            "$ws_url" 2>&1)
    fi

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Check for JSON-RPC error in response
        if echo "$response" | grep -q '"error"'; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.error.message // .error' 2>/dev/null || echo "$response")
            echo "✗ TrueNAS notification failed: $error_msg"
            return 1
        else
            echo "✓ TrueNAS notification sent: $EVENT_TITLE"
            return 0
        fi
    else
        echo "✗ TrueNAS notification failed (websocat exit $exit_code): $response"
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
