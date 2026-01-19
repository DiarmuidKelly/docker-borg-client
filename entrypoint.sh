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
AUTO_INIT="${AUTO_INIT:-false}"
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

# Auto-initialize repository if enabled and not exists
if [ "$AUTO_INIT" = "true" ]; then
    echo "Checking if repository exists..."

    # Try to list repository and capture output
    BORG_CHECK_OUTPUT=$(borg list "$BORG_REPO" 2>&1)
    BORG_CHECK_EXIT=$?

    if [ $BORG_CHECK_EXIT -eq 0 ]; then
        # Repository exists and is accessible
        echo "Repository already exists"

        # Check if key is exported, if not export it
        if [ ! -f /borg/config/repo-key.txt ]; then
            echo "Exporting repository key to /borg/config/repo-key.txt..."
            borg key export "$BORG_REPO" /borg/config/repo-key.txt
            echo "⚠️  Remember to backup /borg/config/repo-key.txt to password manager!"
        fi
    elif echo "$BORG_CHECK_OUTPUT" | grep -q "Lock.*by.*PID"; then
        # Repository is locked (backup in progress or stale lock)
        echo "⚠️  Repository is currently locked (backup may be in progress)"
        echo "If this persists, you may need to break the lock manually:"
        echo "  docker exec <container> borg break-lock $BORG_REPO"
        echo "Continuing anyway - cron will handle scheduled backups..."
    else
        # Repository doesn't exist - initialize it
        echo ""
        echo "Repository not found - initializing automatically..."
        echo ""
        /scripts/init.sh
        echo ""
        echo "Repository initialized! Continuing with startup..."
        echo ""
    fi
    echo "========================================="
fi

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
