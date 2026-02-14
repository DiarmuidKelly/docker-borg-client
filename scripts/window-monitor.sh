#!/bin/sh
# Monitor backup window and terminate when window ends
# Polls for new checkpoints in final 30 minutes to enable early termination

BORG_PID=$1
CHECK_INTERVAL=60       # Check window status every minute
POLL_INTERVAL=300       # Poll for checkpoints every 5 minutes
CHECKPOINT_INTERVAL=1800 # 30 min (Borg default)

if [ -z "$BORG_PID" ]; then
    echo "ERROR: BORG_PID required"
    exit 1
fi

# Calculate window end time in seconds since epoch
get_window_end_epoch() {
    if [ -z "$BACKUP_WINDOW_END" ]; then
        echo "0"
        return
    fi

    # Parse HH:MM format
    HOUR=$(echo "$BACKUP_WINDOW_END" | cut -d: -f1 | sed 's/^0*//')
    MINUTE=$(echo "$BACKUP_WINDOW_END" | cut -d: -f2 | sed 's/^0*//')
    HOUR=${HOUR:-0}
    MINUTE=${MINUTE:-0}

    # Get current time components
    CURRENT_EPOCH=$(date +%s)
    CURRENT_HOUR=$(date +%H | sed 's/^0*//')
    CURRENT_MINUTE=$(date +%M | sed 's/^0*//')
    CURRENT_HOUR=${CURRENT_HOUR:-0}
    CURRENT_MINUTE=${CURRENT_MINUTE:-0}

    # Calculate seconds from midnight to window end
    TARGET_SECONDS=$((HOUR * 3600 + MINUTE * 60))
    CURRENT_SECONDS=$((CURRENT_HOUR * 3600 + CURRENT_MINUTE * 60))

    # Calculate epoch for today's window end
    MIDNIGHT_EPOCH=$((CURRENT_EPOCH - CURRENT_SECONDS))
    WINDOW_END=$((MIDNIGHT_EPOCH + TARGET_SECONDS))

    # If window end is in the past (for overnight windows), use tomorrow
    if [ "$WINDOW_END" -lt "$CURRENT_EPOCH" ]; then
        WINDOW_END=$((WINDOW_END + 86400))
    fi

    echo "$WINDOW_END"
}

WINDOW_END_EPOCH=$(get_window_end_epoch)
INITIAL_CHECKPOINT=""
POLLING_STARTED=0
LAST_POLL_TIME=0

echo "Window monitor active (terminate at window end: $BACKUP_WINDOW_END)"

while kill -0 "$BORG_PID" 2>/dev/null; do
    sleep $CHECK_INTERVAL

    # Check if we're still in window
    if ! /scripts/check-window.sh; then
        # Outside window - check rate limit
        RATE_OUT="${BACKUP_RATE_LIMIT_OUT_WINDOW:--1}"

        if [ "$RATE_OUT" = "0" ]; then
            echo "Window ended, terminating backup (PID: $BORG_PID)..."
            echo "Backup will auto-resume from checkpoint in next window"
            kill -TERM "$BORG_PID"
            exit 0
        fi
    else
        # Inside window - check if we should start polling
        CURRENT_TIME=$(date +%s)
        TIME_UNTIL_WINDOW_END=$((WINDOW_END_EPOCH - CURRENT_TIME))

        # Start polling when we're within checkpoint interval of window end
        if [ "$TIME_UNTIL_WINDOW_END" -le "$CHECKPOINT_INTERVAL" ] && [ "$TIME_UNTIL_WINDOW_END" -gt 0 ]; then
            if [ "$POLLING_STARTED" -eq 0 ]; then
                echo "Window ends in ${TIME_UNTIL_WINDOW_END}s, starting checkpoint polling..."
                POLLING_STARTED=1

                # Capture initial checkpoint state
                INITIAL_CHECKPOINT=$(borg list --json "$BORG_REPO" 2>/dev/null | jq -r '.archives[]? | select(.name | endswith(".checkpoint")) | .name' | tail -1)
                LAST_POLL_TIME=$CURRENT_TIME
            fi

            # Poll every POLL_INTERVAL seconds
            TIME_SINCE_LAST_POLL=$((CURRENT_TIME - LAST_POLL_TIME))
            if [ "$TIME_SINCE_LAST_POLL" -ge "$POLL_INTERVAL" ]; then
                CURRENT_CHECKPOINT=$(borg list --json "$BORG_REPO" 2>/dev/null | jq -r '.archives[]? | select(.name | endswith(".checkpoint")) | .name' | tail -1)

                if [ -n "$CURRENT_CHECKPOINT" ] && [ "$CURRENT_CHECKPOINT" != "$INITIAL_CHECKPOINT" ]; then
                    echo "New checkpoint detected: $CURRENT_CHECKPOINT"
                    echo "Terminating backup early (PID: $BORG_PID) to minimize wasted work..."
                    kill -TERM "$BORG_PID"
                    exit 0
                fi

                LAST_POLL_TIME=$CURRENT_TIME
                echo "Polled for checkpoint (${TIME_UNTIL_WINDOW_END}s until window end)"
            fi
        fi
    fi
done
