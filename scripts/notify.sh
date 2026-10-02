#!/bin/sh
# shellcheck shell=ash
# Records Borg job events to a persistent history file.
#
# This used to push alerts to the TrueNAS API. That never worked:
# alert.oneshot_create accepts the call and returns an ID, but the alert never
# appears in the UI and never triggers any notification service, because only
# predefined system alert classes do (issue #33). Every event was therefore
# silently discarded.
#
# Cron output goes to the container's stdout, which is lost to log rotation, a
# redeploy or an app update - so a failed backup or a verify that detected
# corruption could leave no trace anywhere. This writes instead to
# /borg/config, a persisted volume, so the record survives restarts.
# preflight.sh reads it back on every container start.
#
# The call signature is unchanged, so every existing call site still works.

EVENT_TYPE="${1:-}"      # e.g. backup.success, backup.failure
EVENT_LEVEL="${2:-INFO}" # INFO, WARNING, CRITICAL
EVENT_TITLE="${3:-}"     # Short title
EVENT_MESSAGE="${4:-}"   # Detailed message

HISTORY_FILE="${HISTORY_FILE:-/borg/config/history.log}"
HISTORY_MAX_LINES="${HISTORY_MAX_LINES:-500}"

if [ -z "$EVENT_TYPE" ] || [ -z "$EVENT_TITLE" ]; then
    echo "ERROR: notify.sh requires EVENT_TYPE and EVENT_TITLE"
    exit 1
fi

# Every event is recorded. There is deliberately no event filtering: this is a
# log, not an alert feed, and a history that omitted successes could not show
# whether the last backup worked.
#
# One event per line, so the file stays greppable:
#   <timestamp> <event> <level> <title> | <message>
LINE=$(printf '%s %s %s %s | %s' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    "$EVENT_TYPE" \
    "$EVENT_LEVEL" \
    "$EVENT_TITLE" \
    "$EVENT_MESSAGE" | tr '\n' ' ')

# Never fail the calling job: losing a status line must not break a backup.
if ! mkdir -p "$(dirname "$HISTORY_FILE")" 2>/dev/null; then
    echo "WARNING: cannot create $(dirname "$HISTORY_FILE") - event not recorded"
    exit 0
fi

if ! printf '%s\n' "$LINE" >> "$HISTORY_FILE" 2>/dev/null; then
    echo "WARNING: cannot write $HISTORY_FILE - event not recorded"
    exit 0
fi

# Rolling cap: keep the newest HISTORY_MAX_LINES, drop the oldest.
LINE_COUNT=$(wc -l < "$HISTORY_FILE" 2>/dev/null | tr -d ' ')
case "$LINE_COUNT" in
    ''|*[!0-9]*) LINE_COUNT=0 ;;
esac

if [ "$LINE_COUNT" -gt "$HISTORY_MAX_LINES" ]; then
    if tail -n "$HISTORY_MAX_LINES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null; then
        mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE" 2>/dev/null || rm -f "${HISTORY_FILE}.tmp"
    else
        rm -f "${HISTORY_FILE}.tmp"
    fi
fi

echo "Recorded: $EVENT_TYPE"
exit 0
