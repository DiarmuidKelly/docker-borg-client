#!/bin/sh
set -e

# Integration test script for borg backup container
# Tests our wrapper scripts (init.sh, backup.sh, restore.sh, prune.sh, verify.sh)
# with a real borg repository

echo "========================================="
echo "Integration Tests - Wrapper Scripts"
echo "========================================="
echo ""

# Configuration (set by docker-compose.test.yml)
REPO_PATH="${BORG_REPO:-/repo}"
SOURCE_PATH="${SOURCE_PATH:-/source}"
RESTORE_PATH="/tmp/restored"

# Ensure required env vars are set
export BORG_REPO="$REPO_PATH"
export BORG_PASSPHRASE="${BORG_PASSPHRASE:-test-passphrase}"
export BACKUP_PATHS="$SOURCE_PATH"
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Disable notifications for tests
export NOTIFY_TRUENAS_ENABLED=false

# Set prune retention for testing
export PRUNE_KEEP_DAILY=1
export PRUNE_KEEP_WEEKLY=0
export PRUNE_KEEP_MONTHLY=0

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "FAIL: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Clean up any previous test runs
cleanup() {
    rm -rf "${REPO_PATH:?}"/* "$RESTORE_PATH" 2>/dev/null || true
}

# =========================================
# Test 1: init.sh
# =========================================
echo "--- Test 1: init.sh - Repository Initialisation ---"
cleanup

# Create config directory for key export
mkdir -p /borg/config

if /scripts/init.sh 2>&1; then
    pass "init.sh completed successfully"
else
    fail "init.sh failed"
    exit 1
fi

# Verify key was exported
if [ -f /borg/config/repo-key.txt ]; then
    pass "Repository key exported to /borg/config/repo-key.txt"
else
    fail "Repository key not exported"
fi
echo ""

# =========================================
# Test 2: backup.sh
# =========================================
echo "--- Test 2: backup.sh - Create First Backup ---"

if /scripts/backup.sh 2>&1; then
    pass "backup.sh completed successfully"
else
    fail "backup.sh failed"
    exit 1
fi

# Verify archive was created
ARCHIVE_COUNT=$(borg list "$BORG_REPO" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -ge 1 ]; then
    pass "Archive created (count: $ARCHIVE_COUNT)"
else
    fail "No archive created"
fi
echo ""

# =========================================
# Test 3: restore.sh list
# =========================================
echo "--- Test 3: restore.sh list - List Archives ---"

if /scripts/restore.sh list 2>&1 | grep -q "backup-"; then
    pass "restore.sh list shows archives"
else
    fail "restore.sh list failed to show archives"
fi
echo ""

# =========================================
# Test 4: restore.sh info
# =========================================
echo "--- Test 4: restore.sh info - Archive Info ---"

# Get the archive name
ARCHIVE_NAME=$(borg list "$BORG_REPO" 2>/dev/null | head -1 | awk '{print $1}')

if /scripts/restore.sh info "$ARCHIVE_NAME" 2>&1 | grep -q "Archive name"; then
    pass "restore.sh info shows archive details"
else
    fail "restore.sh info failed"
fi
echo ""

# =========================================
# Test 5: restore.sh extract - Data Integrity
# =========================================
echo "--- Test 5: restore.sh extract - Extract and Verify Data ---"

mkdir -p "$RESTORE_PATH"

if /scripts/restore.sh extract "$ARCHIVE_NAME" "$RESTORE_PATH" 2>&1; then
    pass "restore.sh extract completed"
else
    fail "restore.sh extract failed"
    exit 1
fi

# Compare restored data with source
EXTRACTED_PATH="$RESTORE_PATH$SOURCE_PATH"
if diff -r "$SOURCE_PATH" "$EXTRACTED_PATH" > /dev/null 2>&1; then
    pass "Restored data matches source (byte-for-byte)"
else
    fail "Restored data does not match source"
    echo "Differences:"
    diff -r "$SOURCE_PATH" "$EXTRACTED_PATH" || true
fi
echo ""

# =========================================
# Test 6: verify.sh - Repository Integrity
# =========================================
echo "--- Test 6: verify.sh - Repository Integrity Check ---"

export VERIFY_LEVEL=repository
if /scripts/verify.sh 2>&1; then
    pass "verify.sh (repository level) passed"
else
    fail "verify.sh failed"
fi
echo ""

# =========================================
# Test 7: Second backup for prune test
# =========================================
echo "--- Test 7: backup.sh - Create Second Backup ---"

# Small delay to ensure different timestamp
sleep 2

if /scripts/backup.sh 2>&1; then
    pass "Second backup.sh completed"
else
    fail "Second backup.sh failed"
fi

ARCHIVE_COUNT=$(borg list "$BORG_REPO" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -ge 2 ]; then
    pass "Two archives exist (count: $ARCHIVE_COUNT)"
else
    fail "Expected at least 2 archives, found $ARCHIVE_COUNT"
fi
echo ""

# =========================================
# Test 8: prune.sh - Archive Retention
# =========================================
echo "--- Test 8: prune.sh - Prune Old Archives ---"

# Note: backup.sh already calls prune.sh, but let's test it directly too
# Reset to have multiple archives first
export PRUNE_KEEP_DAILY=1
export PRUNE_KEEP_WEEKLY=0
export PRUNE_KEEP_MONTHLY=0

if /scripts/prune.sh 2>&1; then
    pass "prune.sh completed"
else
    fail "prune.sh failed"
fi

# After prune with keep-daily=1, should have 1 archive
ARCHIVE_COUNT=$(borg list "$BORG_REPO" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -eq 1 ]; then
    pass "Prune retained correct number of archives (1)"
else
    fail "Expected 1 archive after prune, found $ARCHIVE_COUNT"
fi
echo ""

# =========================================
# Test 9: verify.sh archives level
# =========================================
echo "--- Test 9: verify.sh - Archives Integrity Check ---"

export VERIFY_LEVEL=archives
# Override the day check by unsetting the schedule
unset VERIFY_ARCHIVES_CRON_SCHEDULE

if /scripts/verify.sh 2>&1; then
    pass "verify.sh (archives level) passed"
else
    fail "verify.sh (archives level) failed"
fi
echo ""

# =========================================
# Test 10: restore.sh check
# =========================================
echo "--- Test 10: restore.sh check - Full Repository Check ---"

if /scripts/restore.sh check 2>&1; then
    pass "restore.sh check passed"
else
    fail "restore.sh check failed"
fi
echo ""

# =========================================
# Summary
# =========================================
echo "========================================="
echo "Integration Test Results"
echo "========================================="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "========================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "INTEGRATION TESTS FAILED"
    exit 1
else
    echo "ALL INTEGRATION TESTS PASSED"
    exit 0
fi
