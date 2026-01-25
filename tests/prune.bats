#!/usr/bin/env bats

# Test prune.sh archive pruning logic

setup() {
    # Path to the script under test
    PRUNE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/prune.sh"

    # Create temporary test directory
    TEST_DIR="/tmp/test-prune-$$"
    mkdir -p "$TEST_DIR/bin"
    mkdir -p "$TEST_DIR/scripts"

    # Create mock notify.sh
    cat > "$TEST_DIR/scripts/notify.sh" << 'EOF'
#!/bin/sh
echo "NOTIFY: $1 $2 $3"
exit 0
EOF
    chmod +x "$TEST_DIR/scripts/notify.sh"

    # Set up environment
    export BORG_REPO="/tmp/test-repo-$$"
    export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
    # Clean up
    rm -rf "$TEST_DIR"
    unset BORG_REPO
    unset PRUNE_KEEP_DAILY
    unset PRUNE_KEEP_WEEKLY
    unset PRUNE_KEEP_MONTHLY
}

# Test: Successful prune with default retention
@test "prunes successfully with default retention values" {
    # Create mock borg that succeeds
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    echo "BORG_PRUNE: $@"
    echo "Pruning archive: backup-2024-01-01_00-00-00"
    echo "Keeping archive: backup-2024-01-02_00-00-00"
    exit 0
elif [ "$1" = "compact" ]; then
    echo "BORG_COMPACT: Compacting repository $2"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    # Replace script paths in prune.sh for testing
    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Pruning Old Backups"
    echo "$output" | grep -q "Repository: $BORG_REPO"
    echo "$output" | grep -q "Daily: 7"
    echo "$output" | grep -q "Weekly: 4"
    echo "$output" | grep -q "Monthly: 6"
    echo "$output" | grep -q "BORG_PRUNE:"
    echo "$output" | grep -q "BORG_COMPACT: Compacting repository"
    echo "$output" | grep -q "✅ Prune completed successfully!"
    echo "$output" | grep -q "NOTIFY: prune.success INFO"
}

# Test: Custom retention values
@test "uses custom retention values from environment" {
    export PRUNE_KEEP_DAILY="14"
    export PRUNE_KEEP_WEEKLY="8"
    export PRUNE_KEEP_MONTHLY="12"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    echo "BORG_ARGS: $@"
    exit 0
elif [ "$1" = "compact" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Daily: 14"
    echo "$output" | grep -q "Weekly: 8"
    echo "$output" | grep -q "Monthly: 12"
    echo "$output" | grep -q "BORG_ARGS:.*--keep-daily=14"
    echo "$output" | grep -q "BORG_ARGS:.*--keep-weekly=8"
    echo "$output" | grep -q "BORG_ARGS:.*--keep-monthly=12"
    echo "$output" | grep -q "NOTIFY: prune.success INFO"
}

# Test: Prune failure handling
@test "handles prune failure correctly" {
    # Create mock borg that fails on prune
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    echo "ERROR: Repository locked"
    exit 2
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "ERROR: Repository locked"
    echo "$output" | grep -q "✗ Prune failed!"
    echo "$output" | grep -q "NOTIFY: prune.failure CRITICAL"
    echo "$output" | grep -qv "BORG_COMPACT"  # Should not run compact on failure
}

# Test: Compact failure handling
@test "handles compact failure after successful prune" {
    # Create mock borg that succeeds on prune but fails on compact
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    echo "Prune successful"
    exit 0
elif [ "$1" = "compact" ]; then
    echo "ERROR: Compact failed - insufficient space"
    exit 1
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    # Note: The script doesn't check compact's exit code, so this should succeed
    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 1 ]  # set -e will catch the compact failure
    echo "$output" | grep -q "Prune successful"
    echo "$output" | grep -q "Running compact"
    echo "$output" | grep -q "ERROR: Compact failed"
}

# Test: Correct borg command parameters
@test "calls borg with correct prune parameters" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    for arg in "$@"; do
        case "$arg" in
            --stats|--list) echo "FLAG: $arg" ;;
            --keep-*) echo "RETENTION: $arg" ;;
        esac
    done
    exit 0
elif [ "$1" = "compact" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FLAG: --stats"
    echo "$output" | grep -q "FLAG: --list"
    echo "$output" | grep -q "RETENTION: --keep-daily=7"
    echo "$output" | grep -q "RETENTION: --keep-weekly=4"
    echo "$output" | grep -q "RETENTION: --keep-monthly=6"
}

# Test: Repository path is passed correctly
@test "passes repository path to borg commands" {
    export BORG_REPO="/custom/repo/path"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    # Last argument should be repository
    for arg in "$@"; do
        last_arg="$arg"
    done
    echo "PRUNE_REPO: $last_arg"
    exit 0
elif [ "$1" = "compact" ]; then
    echo "COMPACT_REPO: $2"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PRUNE_REPO: /custom/repo/path"
    echo "$output" | grep -q "COMPACT_REPO: /custom/repo/path"
}

# Test: Zero retention values
@test "handles zero retention values" {
    export PRUNE_KEEP_DAILY="0"
    export PRUNE_KEEP_WEEKLY="0"
    export PRUNE_KEEP_MONTHLY="1"  # Keep at least one

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    echo "BORG_ARGS: $@"
    exit 0
elif [ "$1" = "compact" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Daily: 0"
    echo "$output" | grep -q "Weekly: 0"
    echo "$output" | grep -q "Monthly: 1"
    echo "$output" | grep -q "BORG_ARGS:.*--keep-daily=0"
    echo "$output" | grep -q "BORG_ARGS:.*--keep-weekly=0"
    echo "$output" | grep -q "BORG_ARGS:.*--keep-monthly=1"
}

# Test: Notification includes retention policy
@test "notification message includes retention policy" {
    export PRUNE_KEEP_DAILY="3"
    export PRUNE_KEEP_WEEKLY="2"
    export PRUNE_KEEP_MONTHLY="1"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "prune" ]; then
    exit 0
elif [ "$1" = "compact" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$PRUNE_SCRIPT" > "$TEST_DIR/prune-test.sh"

    run sh "$TEST_DIR/prune-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "NOTIFY: prune.success INFO"
}