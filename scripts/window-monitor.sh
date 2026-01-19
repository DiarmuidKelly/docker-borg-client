#!/bin/sh
# Monitor backup window and terminate if needed

BORG_PID=$1
CHECK_INTERVAL=60  # Check every minute

if [ -z "$BORG_PID" ]; then
    echo "ERROR: BORG_PID required"
    exit 1
fi

# Hardcoded grace period (60% of Borg's 30-min default checkpoint interval)
# Borg default checkpoint interval is 1800s (30 min)
# Values < 1800s cause significant performance degradation (cache write storms)
# See: https://github.com/borgbackup/borg/issues/896
#      https://github.com/borgbackup/borg/issues/2841
GRACE_PERIOD=1080  # 18 min (60% of 1800s checkpoint interval)

# Track when we exited window
WINDOW_EXIT_TIME=""

while kill -0 "$BORG_PID" 2>/dev/null; do
    sleep $CHECK_INTERVAL

    # Check if we're still in window
    if ! /scripts/check-window.sh; then
        # Outside window - check rate limit
        RATE_OUT="${BACKUP_RATE_LIMIT_OUT_WINDOW:--1}"

        if [ "$RATE_OUT" = "0" ]; then
            # Record when we first exited window
            if [ -z "$WINDOW_EXIT_TIME" ]; then
                WINDOW_EXIT_TIME=$(date +%s)
                echo "⚠️  Exited backup window, entering grace period (${GRACE_PERIOD}s)..."
                echo "Allowing time to complete current checkpoint..."
            fi

            # Check if grace period has expired
            CURRENT_TIME=$(date +%s)
            OVERRUN=$((CURRENT_TIME - WINDOW_EXIT_TIME))

            if [ "$OVERRUN" -ge "$GRACE_PERIOD" ]; then
                echo "⏹️  Grace period expired, terminating backup (PID: $BORG_PID)..."
                echo "Backup will auto-resume from checkpoint in next window"
                kill -TERM "$BORG_PID"
                exit 0
            fi
        fi
    else
        # Back in window (shouldn't happen, but reset if it does)
        WINDOW_EXIT_TIME=""
    fi
done
