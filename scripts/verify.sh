#!/bin/sh
# shellcheck shell=ash
set -e

# Set default verification level
VERIFY_LEVEL="${VERIFY_LEVEL:-repository}"

# A check needs the repository lock, and a running backup holds it. This script
# used to run `borg break-lock` here unconditionally, on the reasoning that
# "verify takes priority". It does not: break-lock deletes the repository lock
# *and* the local cache lock, so a backup already in progress lost both and then
# died at its next checkpoint with
#   AssertionError: bug in code, exclusive lock should exist here
# followed by NotLocked on the cache it no longer owned (issue #59). With a
# daily backup that runs longer than the gap to the check schedule, that is
# every single week.
#
# A check never interrupts a backup. It waits briefly for the lock - enough to
# cover a backup that is nearly done - and otherwise skips and runs on the next
# schedule. Stale locks left by a container that died mid-backup are cleared at
# startup by entrypoint.sh, which is the only place that can know the holder is
# really gone.
LOCK_WAIT="${VERIFY_LOCK_WAIT:-300}"

case "$LOCK_WAIT" in
    ''|*[!0-9]*)
        echo "ERROR: VERIFY_LOCK_WAIT must be a non-negative integer (got '$LOCK_WAIT')" >&2
        exit 2
        ;;
esac

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
echo "Lock wait: ${LOCK_WAIT}s"
echo ""

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

OUT_FILE=$(mktemp)
RC_FILE=$(mktemp)
trap 'rm -f "$OUT_FILE" "$RC_FILE"' EXIT

# Stream borg's output to the log as it happens - --progress is only useful
# live - while also capturing it, so "could not get the lock" can be told apart
# from "the repository is corrupt". ash has no PIPESTATUS, so the real exit code
# comes back through a file rather than from the pipeline.
# shellcheck disable=SC2086  # BORG_CMD is a deliberately word-split command line
{ set +e; $BORG_CMD --lock-wait "$LOCK_WAIT" "$BORG_REPO" 2>&1; echo $? > "$RC_FILE"; } \
    | tee "$OUT_FILE"

EXIT_CODE=$(cat "$RC_FILE" 2>/dev/null)
case "$EXIT_CODE" in
    ''|*[!0-9]*) EXIT_CODE=2 ;;
esac

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# A lock we could not get is not a verification failure: nothing was checked,
# and nothing is known to be wrong. Recorded all the same, because a check that
# keeps skipping is a check that is not happening - preflight.sh reports it on
# every start.
if [ "$EXIT_CODE" -ne 0 ] \
    && grep -qE "Failed to create/acquire the lock|Lock.*by.*PID" "$OUT_FILE"; then
    echo ""
    echo "SKIPPED: repository is locked (a backup is probably running)."
    echo "Waited ${LOCK_WAIT}s for the lock. This check does not break locks -"
    echo "it will run on the next schedule."
    echo "If this keeps happening, move the verification schedule clear of the"
    echo "backup window (VERIFY_REPO_CRON_SCHEDULE / VERIFY_ARCHIVES_CRON_SCHEDULE)."
    echo "========================================="

    /scripts/notify.sh "verify.skipped" "WARNING" \
        "Borg Verification Skipped" \
        "Level: ${VERIFY_LEVEL}, repository locked after ${LOCK_WAIT}s wait"

    exit 0
fi

if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "Verification completed successfully!"
    echo "Duration: ${DURATION}s"
    echo "========================================="

    # Send success notification
    /scripts/notify.sh "verify.success" "INFO" \
        "Borg Verification Successful" \
        "Level: ${VERIFY_LEVEL}, Duration: ${DURATION}s"
else
    echo ""
    echo "Verification failed!"
    echo "Duration: ${DURATION}s"
    echo "========================================="

    # Send failure notification
    /scripts/notify.sh "verify.failure" "CRITICAL" \
        "Borg Verification Failed" \
        "Level: ${VERIFY_LEVEL}, Exit code: ${EXIT_CODE}, Duration: ${DURATION}s"

    exit "$EXIT_CODE"
fi
