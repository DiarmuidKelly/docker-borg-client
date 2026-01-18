#!/bin/sh
set -e

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
ARCHIVE_NAME="backup-${TIMESTAMP}"

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

# Run backup
echo "Creating backup archive..."
borg create \
    --stats \
    --progress \
    --compression lz4 \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    $PATHS

echo ""
echo "✅ Backup completed successfully!"
echo ""

# Run prune after backup
echo "Running prune to clean up old archives..."
/scripts/prune.sh

echo "========================================="
echo "Backup completed at $(date)"
echo "========================================="
