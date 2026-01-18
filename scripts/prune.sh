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

# Prune old archives
borg prune \
    --stats \
    --list \
    --keep-daily="$PRUNE_KEEP_DAILY" \
    --keep-weekly="$PRUNE_KEEP_WEEKLY" \
    --keep-monthly="$PRUNE_KEEP_MONTHLY" \
    "$BORG_REPO"

echo ""
echo "Running compact to free repository space..."
borg compact "$BORG_REPO"

echo ""
echo "✅ Prune completed successfully!"
echo "========================================="
