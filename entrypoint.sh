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
VERIFY_ENABLED="${VERIFY_ENABLED:-false}"
VERIFY_CRON_SCHEDULE="${VERIFY_CRON_SCHEDULE:-0 3 1 * *}"
BORG_RSH="${BORG_RSH:-ssh -i /ssh/key -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ConnectionAttempts=3}"

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

# Send startup notification
/scripts/notify.sh "container.startup" "INFO" \
    "Borg Backup Container Started" \
    "Repository: ${BORG_REPO}, Schedule: ${CRON_SCHEDULE}"

# Set up shutdown notification trap
shutdown_handler() {
    /scripts/notify.sh "container.shutdown" "INFO" \
        "Borg Backup Container Stopping" \
        "Container shutdown initiated"
}
trap shutdown_handler TERM INT

# Auto-initialize repository if enabled and not exists
if [ "$AUTO_INIT" = "true" ]; then
    echo "Checking if repository exists..."

    # Clear any stale cache locks from previous interrupted sessions
    # Container restart means previous backup is dead, so cache locks are stale
    if [ -d "$BORG_CACHE_DIR" ]; then
        find "$BORG_CACHE_DIR" -name "lock.*" -type f -delete 2>/dev/null || true
    fi

    # Try to list repository and capture output
    # Temporarily disable set -e to capture exit code
    set +e
    BORG_CHECK_OUTPUT=$(borg list "$BORG_REPO" 2>&1)
    BORG_CHECK_EXIT=$?
    set -e

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
        # Repository is locked - container restart means previous backup is dead
        echo "⚠️  Repository locked from previous session, breaking lock..."
        borg break-lock "$BORG_REPO" 2>/dev/null || true
        echo "Lock broken - next backup will resume from checkpoint"
    elif echo "$BORG_CHECK_OUTPUT" | grep -q "Failed to create/acquire the lock"; then
        # Repository or cache is locked - break remote lock and clear local cache locks
        echo "⚠️  Repository locked from previous session, breaking lock..."
        borg break-lock "$BORG_REPO" 2>/dev/null || true
        find "$BORG_CACHE_DIR" -name "lock.*" -type f -delete 2>/dev/null || true
        echo "Lock broken - next backup will proceed normally"
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

# Set up verification cron job if enabled
if [ "$VERIFY_ENABLED" = "true" ]; then
    echo "$VERIFY_CRON_SCHEDULE /scripts/verify.sh >> /proc/1/fd/1 2>&1" >> /etc/crontabs/root
    echo "Verification cron job configured"
fi

# Run backup on start if requested
if [ "$RUN_ON_START" = "true" ]; then
    echo "Running initial backup..."
    /scripts/backup.sh
fi

# Start cron in foreground
echo "Starting cron daemon..."
exec crond -f -l 2
