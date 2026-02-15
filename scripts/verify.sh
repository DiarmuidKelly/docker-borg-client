#!/bin/sh
set -e

# Set default verification level
VERIFY_LEVEL="${VERIFY_LEVEL:-repository}"

# Skip repository check if today is archives day (avoid running both)
if [ "$VERIFY_LEVEL" = "repository" ]; then
    ARCHIVES_DAY=$(echo "${VERIFY_ARCHIVES_CRON_SCHEDULE:-0 3 1 * *}" | awk '{print $3}')
    TODAY=$(date +%d | sed 's/^0//')

    if [ "$ARCHIVES_DAY" = "$TODAY" ]; then
        echo "Skipping repository check - archives check runs today"
        exit 0
    fi
fi

echo "========================================="
echo "Verifying Repository Integrity"
echo "========================================="
echo "Repository: $BORG_REPO"
echo "Verification level: $VERIFY_LEVEL"
echo ""

# Break any existing lock - verify takes priority
# Interrupted backups will resume from checkpoint on next run
echo "Breaking any existing locks..."
borg break-lock "$BORG_REPO" 2>/dev/null || true

START_TIME=$(date +%s)

# Run verification based on level
case "$VERIFY_LEVEL" in
    repository)
        echo "Running repository-only check..."
        BORG_CMD="borg check --repository-only --progress"
        ;;
    archives)
        echo "Running archives-only check..."
        BORG_CMD="borg check --archives-only --progress"
        ;;
    full)
        echo "Running full verification (this may take a long time)..."
        BORG_CMD="borg check --verify-data --progress"
        ;;
    *)
        echo "ERROR: Invalid VERIFY_LEVEL '$VERIFY_LEVEL'"
        echo "Valid options: repository, archives, full"
        exit 1
        ;;
esac

if $BORG_CMD "$BORG_REPO"; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "Verification completed successfully!"
    echo "Duration: ${DURATION}s"
    echo "========================================="

    # Send success notification
    /scripts/notify.sh "verify.success" "INFO" \
        "Borg Verification Successful" \
        "Level: ${VERIFY_LEVEL}, Duration: ${DURATION}s"
else
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "Verification failed!"
    echo "Duration: ${DURATION}s"
    echo "========================================="

    # Send failure notification
    /scripts/notify.sh "verify.failure" "CRITICAL" \
        "Borg Verification Failed" \
        "Level: ${VERIFY_LEVEL}, Exit code: ${EXIT_CODE}, Duration: ${DURATION}s"

    exit $EXIT_CODE
fi
