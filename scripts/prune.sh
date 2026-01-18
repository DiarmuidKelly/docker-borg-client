#!/bin/sh
set -e

# Set defaults for prune retention
PRUNE_KEEP_DAILY="${PRUNE_KEEP_DAILY:-7}"
PRUNE_KEEP_WEEKLY="${PRUNE_KEEP_WEEKLY:-4}"
PRUNE_KEEP_MONTHLY="${PRUNE_KEEP_MONTHLY:-6}"

echo "========================================="
echo "Pruning Old Backups"
echo "========================================="
echo "Repository: $BORG_REPO"
echo "Retention policy:"
echo "  - Daily: $PRUNE_KEEP_DAILY"
echo "  - Weekly: $PRUNE_KEEP_WEEKLY"
echo "  - Monthly: $PRUNE_KEEP_MONTHLY"
echo ""

# Prune old archives with error handling
if borg prune \
    --stats \
    --list \
    --keep-daily="$PRUNE_KEEP_DAILY" \
    --keep-weekly="$PRUNE_KEEP_WEEKLY" \
    --keep-monthly="$PRUNE_KEEP_MONTHLY" \
    "$BORG_REPO" ; then

    echo ""
    echo "Running compact to free repository space..."
    borg compact "$BORG_REPO"

    echo ""
    echo "✅ Prune completed successfully!"
    echo "========================================="

    # Send success notification
    /scripts/notify.sh "prune.success" "INFO" \
        "Borg Prune Successful" \
        "Retention: ${PRUNE_KEEP_DAILY}d/${PRUNE_KEEP_WEEKLY}w/${PRUNE_KEEP_MONTHLY}m"
else
    EXIT_CODE=$?
    echo ""
    echo "✗ Prune failed!"
    echo "========================================="

    # Send failure notification
    /scripts/notify.sh "prune.failure" "CRITICAL" \
        "Borg Prune Failed" \
        "Exit code: ${EXIT_CODE}"

    exit $EXIT_CODE
fi
