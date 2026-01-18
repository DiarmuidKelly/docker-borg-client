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

# Convert colon-separated paths to space-separated for borg
PATHS=$(echo "$BACKUP_PATHS" | tr ':' ' ')

# Run backup with error handling
echo "Creating backup archive..."
if borg create \
    --stats \
    --progress \
    --compression lz4 \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    $PATHS ; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    # Get backup statistics
    STATS=$(borg info --last 1 "${BORG_REPO}" 2>/dev/null || echo "Stats unavailable")

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
