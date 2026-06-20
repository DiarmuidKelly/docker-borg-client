#!/bin/sh
set -e

# Set up SSH command early so it's available for both direct commands and daemon mode
BORG_RSH="${BORG_RSH:-ssh -i /ssh/key -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ConnectionAttempts=3}"
export BORG_RSH

# If a command is passed directly (e.g. docker run image /scripts/verify.sh),
# skip daemon setup and run it immediately with the SSH env already set.
if [ $# -gt 0 ]; then
    exec "$@"
fi

# Validate required environment variables
if [ -z "$BORG_REPO" ]; then
    echo "ERROR: BORG_REPO environment variable is required"
    exit 1
fi

# Support the Docker secret convention: read the passphrase from a mounted file
# (e.g. on an encrypted dataset) so it never lives in the orchestrator's config.
if [ -n "${BORG_PASSPHRASE_FILE:-}" ] && [ -f "$BORG_PASSPHRASE_FILE" ]; then
    BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
    export BORG_PASSPHRASE
fi

# A passphrase must be available via one of three mechanisms. BORG_PASSCOMMAND
# is borg-native and keeps the secret out of the environment entirely.
if [ -z "${BORG_PASSPHRASE:-}" ] && [ -z "${BORG_PASSCOMMAND:-}" ]; then
    echo "ERROR: a passphrase is required - set one of:"
    echo "  BORG_PASSPHRASE       (passphrase in env var)"
    echo "  BORG_PASSPHRASE_FILE  (path to a file containing the passphrase)"
    echo "  BORG_PASSCOMMAND      (command that prints the passphrase, e.g. 'cat /run/secrets/passphrase')"
    exit 1
fi

if [ -z "$BACKUP_PATHS" ]; then
    echo "ERROR: BACKUP_PATHS environment variable is required"
    exit 1
fi

# Set defaults
RUN_ON_START="${RUN_ON_START:-false}"
AUTO_INIT="${AUTO_INIT:-false}"
VERIFY_ENABLED="${VERIFY_ENABLED:-false}"

echo "========================================="
echo "Borg Backup Container Starting"
echo "========================================="
echo "Repository: $BORG_REPO"
echo "Backup paths: $BACKUP_PATHS"
if [ -n "${CRON_SCHEDULE:-}" ]; then
    echo "Cron schedule: $CRON_SCHEDULE"
else
    echo "Cron schedule: none (on-demand only)"
fi
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

# Set up cron job if a schedule is configured
if [ -n "${CRON_SCHEDULE:-}" ] && [ "$CRON_SCHEDULE" != "false" ] && [ "$CRON_SCHEDULE" != "none" ]; then
    echo "$CRON_SCHEDULE /scripts/backup.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
    echo "Cron job configured: $CRON_SCHEDULE"
else
    : > /etc/crontabs/root
    echo "No backup cron schedule set - running on-demand only"
fi

# Set up verification cron jobs if enabled
if [ "$VERIFY_ENABLED" = "true" ]; then
    if [ -n "${VERIFY_REPO_CRON_SCHEDULE:-}" ] && [ "$VERIFY_REPO_CRON_SCHEDULE" != "false" ] && [ "$VERIFY_REPO_CRON_SCHEDULE" != "none" ]; then
        echo "$VERIFY_REPO_CRON_SCHEDULE VERIFY_LEVEL=repository /scripts/verify.sh >> /proc/1/fd/1 2>&1" >> /etc/crontabs/root
        echo "Repository verification cron configured: $VERIFY_REPO_CRON_SCHEDULE"
    fi
    if [ -n "${VERIFY_ARCHIVES_CRON_SCHEDULE:-}" ] && [ "$VERIFY_ARCHIVES_CRON_SCHEDULE" != "false" ] && [ "$VERIFY_ARCHIVES_CRON_SCHEDULE" != "none" ]; then
        echo "$VERIFY_ARCHIVES_CRON_SCHEDULE VERIFY_LEVEL=archives /scripts/verify.sh >> /proc/1/fd/1 2>&1" >> /etc/crontabs/root
        echo "Archives verification cron configured: $VERIFY_ARCHIVES_CRON_SCHEDULE"
    fi
fi

# Run backup on start if requested
if [ "$RUN_ON_START" = "true" ]; then
    echo "Running initial backup..."
    /scripts/backup.sh
fi

# Start cron in foreground
echo "Starting cron daemon..."
exec crond -f -l 2
