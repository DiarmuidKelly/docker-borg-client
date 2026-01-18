#!/bin/sh
set -e

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
ARCHIVE_NAME="backup-${TIMESTAMP}"
START_TIME=$(date +%s)

echo "========================================="
echo "Starting Borg Backup"
echo "========================================="
echo "Time: $(date)"
echo "Archive: $ARCHIVE_NAME"
echo "Repository: $BORG_REPO"
echo "Paths: $BACKUP_PATHS"
echo ""

# Check if we're within backup window (if configured)
check_backup_window() {
    # If no window configured, always allow backup
    if [ -z "$BACKUP_WINDOW_START" ] || [ -z "$BACKUP_WINDOW_END" ]; then
        return 0
    fi

    CURRENT_TIME=$(date +%H:%M)

    # Simple time comparison (works for same-day windows like 01:00-07:00)
    if [ "$BACKUP_WINDOW_START" \< "$BACKUP_WINDOW_END" ]; then
        # Normal window (e.g., 01:00-07:00)
        if [ "$CURRENT_TIME" \>= "$BACKUP_WINDOW_START" ] && [ "$CURRENT_TIME" \< "$BACKUP_WINDOW_END" ]; then
            return 0  # Inside window
        else
            return 1  # Outside window
        fi
    else
        # Overnight window (e.g., 22:00-06:00)
        if [ "$CURRENT_TIME" \>= "$BACKUP_WINDOW_START" ] || [ "$CURRENT_TIME" \< "$BACKUP_WINDOW_END" ]; then
            return 0  # Inside window
        else
            return 1  # Outside window
        fi
    fi
}

# Determine rate limit based on window
RATE_LIMIT_MBPS=-1  # Default: unlimited

if check_backup_window; then
    echo "✓ Inside backup window"
    RATE_LIMIT_MBPS="${BACKUP_RATE_LIMIT_IN_WINDOW:--1}"
else
    echo "⚠ Outside backup window"
    RATE_LIMIT_MBPS="${BACKUP_RATE_LIMIT_OUT_WINDOW:--1}"

    # If rate limit is 0 (stopped), exit gracefully
    if [ "$RATE_LIMIT_MBPS" = "0" ]; then
        echo "Backup stopped outside window (BACKUP_RATE_LIMIT_OUT_WINDOW=0)"
        echo "Next backup will run during window: ${BACKUP_WINDOW_START}-${BACKUP_WINDOW_END}"
        exit 0
    fi
fi

# Convert Mbps to KB/s for Borg (Mbps * 1000 / 8 / 1.024 ≈ Mbps * 122)
BORG_RATE_LIMIT=""
if [ "$RATE_LIMIT_MBPS" != "-1" ]; then
    RATE_LIMIT_KBS=$((RATE_LIMIT_MBPS * 122))
    BORG_RATE_LIMIT="--upload-ratelimit $RATE_LIMIT_KBS"
    echo "Rate limit: ${RATE_LIMIT_MBPS} Mbps (~${RATE_LIMIT_KBS} KB/s)"
else
    echo "Rate limit: unlimited"
fi

# Convert colon-separated paths to space-separated for borg
PATHS=$(echo "$BACKUP_PATHS" | tr ':' ' ')

# Run backup with error handling
echo "Creating backup archive..."
# shellcheck disable=SC2086
if borg create \
    --stats \
    --progress \
    --compression lz4 \
    $BORG_RATE_LIMIT \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    $PATHS ; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "✅ Backup completed successfully!"
    echo "Duration: ${DURATION}s"
    echo ""

    # Send success notification
    /scripts/notify.sh "backup.success" "INFO" \
        "Borg Backup Successful" \
        "Archive: ${ARCHIVE_NAME}, Duration: ${DURATION}s"

    # Run prune after backup
    echo "Running prune to clean up old archives..."
    /scripts/prune.sh

    echo "========================================="
    echo "Backup completed at $(date)"
    echo "========================================="
else
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "✗ Backup failed!"
    echo ""

    # Send failure notification
    /scripts/notify.sh "backup.failure" "CRITICAL" \
        "Borg Backup Failed" \
        "Archive: ${ARCHIVE_NAME}, Exit code: ${EXIT_CODE}, Duration: ${DURATION}s"

    exit $EXIT_CODE
fi
