#!/bin/sh
set -e

# Validate required environment variables
if [ -z "$BORG_REPO" ]; then
    echo "ERROR: BORG_REPO environment variable is required"
    exit 1
fi

if [ -z "$BORG_PASSPHRASE" ]; then
    echo "ERROR: BORG_PASSPHRASE environment variable is required"
    exit 1
fi

if [ -z "$BACKUP_PATHS" ]; then
    echo "ERROR: BACKUP_PATHS environment variable is required"
    exit 1
fi

# Set defaults
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * 0}"
RUN_ON_START="${RUN_ON_START:-false}"
BORG_RSH="${BORG_RSH:-ssh -i /ssh/key -o StrictHostKeyChecking=accept-new}"

export BORG_RSH

echo "========================================="
echo "Borg Backup Container Starting"
echo "========================================="
echo "Repository: $BORG_REPO"
echo "Backup paths: $BACKUP_PATHS"
echo "Cron schedule: $CRON_SCHEDULE"
echo "Run on start: $RUN_ON_START"

# Display time window configuration if set
if [ -n "$BACKUP_WINDOW_START" ] && [ -n "$BACKUP_WINDOW_END" ]; then
    echo "Backup window: ${BACKUP_WINDOW_START}-${BACKUP_WINDOW_END}"
    echo "Rate limit in window: ${BACKUP_RATE_LIMIT_IN_WINDOW:--1} Mbps"
    echo "Rate limit out window: ${BACKUP_RATE_LIMIT_OUT_WINDOW:--1} Mbps"
fi

echo "========================================="

# Set up cron job
echo "$CRON_SCHEDULE /scripts/backup.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
echo "Cron job configured"

# Run backup on start if requested
if [ "$RUN_ON_START" = "true" ]; then
    echo "Running initial backup..."
    /scripts/backup.sh
fi

# Start cron in foreground
echo "Starting cron daemon..."
exec crond -f -l 2
