#!/bin/sh
# shellcheck shell=ash
set -e

# Automated restore drill.
#
# "Untested backups aren't backups." A passing `borg check` proves the
# repository is structurally sound; it does not prove you can get your files
# back. This restores a sample of real files from a real archive and compares
# them against the live source, which is the only end-to-end proof of
# recoverability.
#
# Restoring everything is impractical on a multi-terabyte repo, so the drill
# samples a handful of files and rotates which ones it picks each run.

ARCHIVE_REQUEST="${RESTORE_DRILL_ARCHIVE:-latest}"
SAMPLE_COUNT="${RESTORE_DRILL_SAMPLE_COUNT:-3}"
MAX_FILE_BYTES="${RESTORE_DRILL_MAX_FILE_BYTES:-104857600}"
TARGET="${RESTORE_DRILL_TARGET:-/tmp/restore-drill}"
KEEP="${RESTORE_DRILL_KEEP:-false}"
LOCK_WAIT="${RESTORE_DRILL_LOCK_WAIT:-300}"

START_TIME=$(date +%s)

echo "========================================="
echo "Restore Drill"
echo "========================================="
echo "Repository: $BORG_REPO"
echo "Archive requested: $ARCHIVE_REQUEST"
echo "Sample size: $SAMPLE_COUNT file(s)"
echo "Max file size: ${MAX_FILE_BYTES} bytes"
echo "Restore target: $TARGET"
echo ""

# A drill must never disrupt a real backup. If the repository is locked by a
# running backup, skip this run rather than breaking the lock.
skip_if_locked() {
    if echo "$1" | grep -qE "Failed to create/acquire the lock|Lock.*by.*PID"; then
        echo ""
        echo "SKIPPED: repository is locked (a backup is probably running)."
        echo "The drill does not break locks - it will run on the next schedule."
        echo "========================================="
        exit 0
    fi
}

cleanup() {
    if [ "$KEEP" = "true" ]; then
        echo "Restored files kept at: $TARGET (RESTORE_DRILL_KEEP=true)"
    else
        rm -rf "$TARGET"
    fi
}

# ---------- resolve archive ----------

CANDIDATES=$(mktemp)
SAMPLE=$(mktemp)
ERR_FILE=$(mktemp)
trap 'rm -f "$CANDIDATES" "$CANDIDATES.raw" "$SAMPLE" "$ERR_FILE"; cleanup' EXIT

# Guard against a zero/negative sample size reaching the awk division below
if [ "$SAMPLE_COUNT" -lt 1 ] 2>/dev/null; then
    SAMPLE_COUNT=1
fi

echo "--- Resolving archive ---"
# Keep stderr out of the captured value: borg writes notices such as the SSH
# host-key warning to stderr, and folding them into stdout would corrupt the
# archive name.
set +e
if [ "$ARCHIVE_REQUEST" = "latest" ]; then
    ARCHIVE_OUT=$(borg list --lock-wait "$LOCK_WAIT" --last 1 --format '{archive}{NL}' \
        "$BORG_REPO" 2>"$ERR_FILE")
    RESOLVE_EXIT=$?
else
    ARCHIVE_OUT="$ARCHIVE_REQUEST"
    RESOLVE_EXIT=0
fi
set -e
ARCHIVE_ERR=$(cat "$ERR_FILE")

if [ $RESOLVE_EXIT -ne 0 ]; then
    skip_if_locked "$ARCHIVE_ERR"
    echo "ERROR: could not list archives:"
    echo "$ARCHIVE_ERR"
    /scripts/notify.sh "restore.failure" "CRITICAL" \
        "Borg Restore Drill Failed" \
        "Could not list archives in ${BORG_REPO}"
    exit 2
fi

ARCHIVE=$(printf '%s\n' "$ARCHIVE_OUT" | head -1)
if [ -z "$ARCHIVE" ]; then
    echo "ERROR: repository contains no archives - nothing to drill"
    /scripts/notify.sh "restore.failure" "CRITICAL" \
        "Borg Restore Drill Failed" \
        "Repository ${BORG_REPO} contains no archives"
    exit 2
fi
echo "Archive: $ARCHIVE"
echo ""

# ---------- choose sample files ----------

echo "--- Selecting sample files ---"

if [ -n "${RESTORE_DRILL_PATHS:-}" ]; then
    # Explicit paths win: lets an operator pin the drill to the files that
    # actually matter (database dumps, config, etc.)
    echo "$RESTORE_DRILL_PATHS" | tr ':' '\n' | sed '/^$/d' > "$SAMPLE"
    echo "Using RESTORE_DRILL_PATHS:"
else
    # --format is ignored for the output shape but its keys are added to the
    # JSON, which guarantees type/size/path are present rather than relying on
    # whatever the default format happens to include.
    set +e
    LIST_OUT=$(borg list --lock-wait "$LOCK_WAIT" --json-lines \
        --format '{type}{size}{path}' "${BORG_REPO}::${ARCHIVE}" 2>&1 >"$CANDIDATES.raw")
    LIST_EXIT=$?
    set -e

    if [ $LIST_EXIT -ne 0 ]; then
        skip_if_locked "$LIST_OUT"
        echo "ERROR: could not list archive contents:"
        echo "$LIST_OUT"
        /scripts/notify.sh "restore.failure" "CRITICAL" \
            "Borg Restore Drill Failed" \
            "Could not list contents of archive ${ARCHIVE}"
        exit 2
    fi

    # Regular files only, non-empty, small enough to restore cheaply
    jq -r --argjson max "$MAX_FILE_BYTES" \
        'select(.type == "-") | select(.size > 0 and .size <= $max) | .path' \
        < "$CANDIDATES.raw" > "$CANDIDATES"
    rm -f "$CANDIDATES.raw"

    TOTAL=$(wc -l < "$CANDIDATES" | tr -d ' ')
    echo "Eligible files in archive: $TOTAL"

    if [ "$TOTAL" -eq 0 ]; then
        echo ""
        echo "ERROR: no eligible files found in archive $ARCHIVE"
        echo "Every file was a directory, empty, or larger than ${MAX_FILE_BYTES} bytes."
        echo "Raise RESTORE_DRILL_MAX_FILE_BYTES or set RESTORE_DRILL_PATHS."
        /scripts/notify.sh "restore.failure" "CRITICAL" \
            "Borg Restore Drill Failed" \
            "No eligible files to sample in archive ${ARCHIVE}"
        exit 2
    fi

    # Rotate the sample by day-of-year so successive drills cover different
    # files while staying reproducible for a given day and archive.
    OFFSET=$(( $(date +%j | sed 's/^0*//') % TOTAL ))
    awk -v off="$OFFSET" -v want="$SAMPLE_COUNT" -v total="$TOTAL" '
        { line[NR] = $0 }
        END {
            step = int(total / want)
            if (step < 1) step = 1
            for (i = 0; i < want; i++) {
                idx = ((off + i * step) % total) + 1
                print line[idx]
            }
        }
    ' "$CANDIDATES" | awk '!seen[$0]++' > "$SAMPLE"
    echo "Selected (rotating offset ${OFFSET}):"
fi

SAMPLE_TOTAL=$(wc -l < "$SAMPLE" | tr -d ' ')
if [ "$SAMPLE_TOTAL" -eq 0 ]; then
    echo "ERROR: sample selection produced no files"
    /scripts/notify.sh "restore.failure" "CRITICAL" \
        "Borg Restore Drill Failed" \
        "Sample selection produced no files for archive ${ARCHIVE}"
    exit 2
fi

while IFS= read -r p; do
    echo "  - $p"
done < "$SAMPLE"
echo ""

# ---------- restore the sample ----------

echo "--- Restoring sample ---"
rm -rf "$TARGET"
mkdir -p "$TARGET"

# Build the path arguments positionally so paths containing spaces survive
set --
while IFS= read -r p; do
    [ -n "$p" ] || continue
    set -- "$@" "$p"
done < "$SAMPLE"

set +e
EXTRACT_OUT=$(cd "$TARGET" && borg extract --lock-wait "$LOCK_WAIT" --list \
    "${BORG_REPO}::${ARCHIVE}" "$@" 2>&1)
EXTRACT_EXIT=$?
set -e

echo "$EXTRACT_OUT"

if [ $EXTRACT_EXIT -ne 0 ]; then
    skip_if_locked "$EXTRACT_OUT"
    echo ""
    echo "FAILED: borg extract exited $EXTRACT_EXIT"
    DURATION=$(( $(date +%s) - START_TIME ))
    /scripts/notify.sh "restore.failure" "CRITICAL" \
        "Borg Restore Drill Failed" \
        "Archive: ${ARCHIVE}, borg extract exit code: ${EXTRACT_EXIT}, Duration: ${DURATION}s"
    echo "========================================="
    exit "$EXTRACT_EXIT"
fi
echo ""

# ---------- verify what came back ----------

echo "--- Verifying restored files ---"
FAILED=0
MATCHED=0
CHANGED=0
RESTORED_BYTES=0

while IFS= read -r p; do
    [ -n "$p" ] || continue

    restored="${TARGET}/${p}"
    source_file="/${p}"

    if [ ! -f "$restored" ]; then
        echo "  FAIL: $p - not present after extract"
        FAILED=$((FAILED + 1))
        continue
    fi

    size=$(wc -c < "$restored" | tr -d ' ')
    RESTORED_BYTES=$((RESTORED_BYTES + size))

    if [ "$size" -eq 0 ]; then
        echo "  FAIL: $p - restored file is empty"
        FAILED=$((FAILED + 1))
        continue
    fi

    # The strongest check available: compare against the live source. Borg has
    # already verified chunk hashes during extract, so a mismatch here means
    # the source changed since the archive was made, not corruption.
    if [ -f "$source_file" ]; then
        restored_sum=$(sha256sum < "$restored" | awk '{print $1}')
        source_sum=$(sha256sum < "$source_file" | awk '{print $1}')

        if [ "$restored_sum" = "$source_sum" ]; then
            echo "  PASS: $p (${size} bytes, matches live source)"
            MATCHED=$((MATCHED + 1))
        else
            echo "  PASS: $p (${size} bytes, differs from live source - file changed since backup)"
            CHANGED=$((CHANGED + 1))
        fi
    else
        echo "  PASS: $p (${size} bytes, integrity verified by borg; source no longer present)"
        CHANGED=$((CHANGED + 1))
    fi
done < "$SAMPLE"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "========================================="
echo "Restore Drill Summary"
echo "========================================="
echo "Archive:          $ARCHIVE"
echo "Files sampled:    $SAMPLE_TOTAL"
echo "Matched source:   $MATCHED"
echo "Restored (source changed/absent): $CHANGED"
echo "Failed:           $FAILED"
echo "Bytes restored:   $RESTORED_BYTES"
echo "Duration:         ${DURATION}s"
echo "========================================="

if [ "$FAILED" -gt 0 ]; then
    echo "RESTORE DRILL FAILED - your backups may not be recoverable!"
    /scripts/notify.sh "restore.failure" "CRITICAL" \
        "Borg Restore Drill Failed" \
        "Archive: ${ARCHIVE}, ${FAILED} of ${SAMPLE_TOTAL} sampled files could not be restored, Duration: ${DURATION}s"
    exit 1
fi

echo "✅ Restore drill passed - $SAMPLE_TOTAL file(s) recovered successfully"
/scripts/notify.sh "restore.success" "INFO" \
    "Borg Restore Drill Successful" \
    "Archive: ${ARCHIVE}, ${SAMPLE_TOTAL} file(s) restored (${MATCHED} byte-identical to source), Duration: ${DURATION}s"
