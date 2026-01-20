#!/bin/sh
set -e

# Create new timestamped archive
# Note: Borg automatically handles checkpoint resume if interrupted
# See: https://borgbackup.readthedocs.io/en/stable/faq.html#if-a-backup-stops-mid-way-does-the-already-backed-up-data-stay-there
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
ARCHIVE_NAME="backup-${TIMESTAMP}"
echo "Starting backup: $ARCHIVE_NAME"

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
    /scripts/check-window.sh
}

# Determine rate limit based on window
RATE_LIMIT_MBPS=-1  # Default: unlimited

if check_backup_window; then
    echo "Inside backup window"
    RATE_LIMIT_MBPS="${BACKUP_RATE_LIMIT_IN_WINDOW:--1}"
else
    echo "WARNING: Outside backup window"
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

# Spawn borg in background to capture its PID
# shellcheck disable=SC2086
borg create \
    --stats \
    --progress \
    --compression lz4 \
    $BORG_RATE_LIMIT \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    $PATHS &

BORG_PID=$!

# Give borg a moment to start (needs time to initialize Python + SSH connection)
sleep 2

# Verify the process exists (borg runs via python, so we check PID exists, not name)
if ! kill -0 $BORG_PID 2>/dev/null; then
    echo "ERROR: Failed to start borg or capture PID"
    wait $BORG_PID 2>/dev/null || exit 1
    exit $?
fi

echo "Borg process started (PID: $BORG_PID)"

# Spawn window monitor with verified borg PID
MONITOR_PID=""
if [ "${BACKUP_RATE_LIMIT_OUT_WINDOW:-}" = "0" ]; then
    /scripts/window-monitor.sh $BORG_PID &
    MONITOR_PID=$!
    echo "Window monitor started (PID: $MONITOR_PID)"
fi

# Wait for borg to complete
wait $BORG_PID
EXIT_CODE=$?

# Wait for monitor to exit (it exits automatically when borg exits)
if [ -n "$MONITOR_PID" ]; then
    wait "$MONITOR_PID" 2>/dev/null || true
fi

if [ $EXIT_CODE -eq 0 ]; then
    # Success - checkpoint archives will be auto-cleaned by prune
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "Backup completed successfully!"
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

elif [ $EXIT_CODE -eq 143 ]; then
    # SIGTERM (killed by window monitor at window end or after checkpoint)
    echo ""
    echo "INFO: Backup terminated by window monitor"
    echo "Will resume from checkpoint in next window"
    echo ""
    exit 0  # Don't treat as failure

else
    # Genuine failure
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "ERROR: Backup failed!"
    echo ""

    # Send failure notification
    /scripts/notify.sh "backup.failure" "CRITICAL" \
        "Borg Backup Failed" \
        "Archive: ${ARCHIVE_NAME}, Exit code: ${EXIT_CODE}, Duration: ${DURATION}s"

    exit $EXIT_CODE
fi

# Monitor exits automatically when borg exits
