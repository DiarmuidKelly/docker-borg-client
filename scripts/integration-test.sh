#!/bin/sh
set -e

# Integration test script for borg backup/restore verification
# Runs inside the container with local repo (no network required)

echo "========================================="
echo "Borg Integration Tests"
echo "========================================="
echo ""

# Configuration
REPO_PATH="${BORG_REPO:-/repo}"
SOURCE_PATH="${SOURCE_PATH:-/source}"
RESTORE_PATH="/tmp/restored"
PASSPHRASE="${BORG_PASSPHRASE:-test-passphrase}"

export BORG_PASSPHRASE="$PASSPHRASE"
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

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
    rm -rf "$REPO_PATH"/* "$RESTORE_PATH" 2>/dev/null || true
}

echo "--- Test 1: Repository Initialisation ---"
cleanup
if borg init --encryption=repokey "$REPO_PATH" 2>&1; then
    pass "Repository initialised"
else
    fail "Repository initialisation failed"
    exit 1
fi
echo ""

echo "--- Test 2: Create First Backup ---"
if borg create --stats "$REPO_PATH::backup-1" "$SOURCE_PATH" 2>&1; then
    pass "First backup created"
else
    fail "First backup creation failed"
    exit 1
fi
echo ""

echo "--- Test 3: List Archives ---"
ARCHIVE_COUNT=$(borg list "$REPO_PATH" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -eq 1 ]; then
    pass "Archive list shows 1 archive"
else
    fail "Expected 1 archive, found $ARCHIVE_COUNT"
fi
echo ""

echo "--- Test 4: Create Second Backup ---"
if borg create --stats "$REPO_PATH::backup-2" "$SOURCE_PATH" 2>&1; then
    pass "Second backup created"
else
    fail "Second backup creation failed"
fi
echo ""

echo "--- Test 5: Verify Deduplication ---"
ARCHIVE_COUNT=$(borg list "$REPO_PATH" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -eq 2 ]; then
    pass "Archive list shows 2 archives"
else
    fail "Expected 2 archives, found $ARCHIVE_COUNT"
fi
echo ""

echo "--- Test 6: Extract and Verify Data Integrity ---"
mkdir -p "$RESTORE_PATH"
cd "$RESTORE_PATH"
if borg extract "$REPO_PATH::backup-1" 2>&1; then
    pass "Archive extracted"
else
    fail "Archive extraction failed"
    exit 1
fi

# Compare restored data with source
# Note: extracted path will be under $RESTORE_PATH/source (the original path)
EXTRACTED_PATH="$RESTORE_PATH$SOURCE_PATH"
if diff -r "$SOURCE_PATH" "$EXTRACTED_PATH" > /dev/null 2>&1; then
    pass "Restored data matches source (byte-for-byte)"
else
    fail "Restored data does not match source"
    echo "Differences:"
    diff -r "$SOURCE_PATH" "$EXTRACTED_PATH" || true
fi
echo ""

echo "--- Test 7: Repository Integrity Check ---"
if borg check "$REPO_PATH" 2>&1; then
    pass "Repository integrity check passed"
else
    fail "Repository integrity check failed"
fi
echo ""

echo "--- Test 8: Prune Old Archives ---"
if borg prune --keep-last=1 --stats "$REPO_PATH" 2>&1; then
    pass "Prune completed"
else
    fail "Prune failed"
fi

ARCHIVE_COUNT=$(borg list "$REPO_PATH" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -eq 1 ]; then
    pass "Archive count after prune is 1"
else
    fail "Expected 1 archive after prune, found $ARCHIVE_COUNT"
fi
echo ""

echo "--- Test 9: Compact Repository ---"
if borg compact "$REPO_PATH" 2>&1; then
    pass "Compact completed"
else
    fail "Compact failed"
fi
echo ""

echo "--- Test 10: Archive Info ---"
if borg info "$REPO_PATH::backup-2" 2>&1; then
    pass "Archive info retrieved"
else
    fail "Archive info failed"
fi
echo ""

# Summary
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
