#!/usr/bin/env bats

# Test entrypoint.sh lock handling logic

setup() {
    # Create temporary test directory
    TEST_DIR="/tmp/test-entrypoint-$$"
    mkdir -p "$TEST_DIR/bin"
    mkdir -p "$TEST_DIR/borg/cache"
    mkdir -p "$TEST_DIR/borg/config"
    mkdir -p "$TEST_DIR/scripts"

    # Set up environment
    export BORG_REPO="/tmp/test-repo-$$"
    export BORG_PASSPHRASE="test-passphrase"
    export BACKUP_PATHS="/data"
    export BORG_CACHE_DIR="$TEST_DIR/borg/cache"
    export AUTO_INIT="true"
    export PATH="$TEST_DIR/bin:$PATH"

    # Track borg commands
    export BORG_COMMANDS_FILE="$TEST_DIR/borg-commands.log"
}

teardown() {
    rm -rf "$TEST_DIR"
    rm -rf "$BORG_REPO"
    unset BORG_REPO
    unset BORG_PASSPHRASE
    unset BACKUP_PATHS
    unset BORG_CACHE_DIR
    unset AUTO_INIT
    unset BORG_COMMANDS_FILE
}

# Helper to create entrypoint test script (extracts lock handling logic only)
create_lock_handling_test_script() {
    cat > "$TEST_DIR/lock-handling-test.sh" << 'EOF'
#!/bin/sh
set -e

BORG_CACHE_DIR="${BORG_CACHE_DIR:-/borg/cache}"

# Simulate AUTO_INIT logic
if [ "$AUTO_INIT" = "true" ]; then
    echo "Checking if repository exists..."

    if [ -d "$BORG_CACHE_DIR" ]; then
        find "$BORG_CACHE_DIR" -name "lock.*" -type f -delete 2>/dev/null || true
    fi

    # Temporarily disable set -e to capture exit code
    set +e
    BORG_CHECK_OUTPUT=$(borg list "$BORG_REPO" 2>&1)
    BORG_CHECK_EXIT=$?
    set -e

    if [ $BORG_CHECK_EXIT -eq 0 ]; then
        echo "Repository already exists"
    elif echo "$BORG_CHECK_OUTPUT" | grep -q "Lock.*by.*PID"; then
        echo "⚠️  Repository locked from previous session, breaking lock..."
        borg break-lock "$BORG_REPO" 2>/dev/null || true
        echo "Lock broken - next backup will resume from checkpoint"
    elif echo "$BORG_CHECK_OUTPUT" | grep -q "Failed to create/acquire the lock"; then
        echo "⚠️  Repository locked from previous session, breaking lock..."
        borg break-lock "$BORG_REPO" 2>/dev/null || true
        find "$BORG_CACHE_DIR" -name "lock.*" -type f -delete 2>/dev/null || true
        echo "Lock broken - next backup will proceed normally"
    else
        echo "Repository not found - would initialize"
    fi
fi
EOF
    chmod +x "$TEST_DIR/lock-handling-test.sh"
}

# Test: Lock is broken when "Failed to create/acquire the lock" error occurs
@test "breaks remote lock when 'Failed to create/acquire the lock' error" {
    create_lock_handling_test_script

    # Create mock borg that returns lock error on list, logs break-lock call
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "$@" >> "$BORG_COMMANDS_FILE"
if [ "$1" = "list" ]; then
    echo "Failed to create/acquire the lock /home/borg-backups/lock.exclusive (timeout)." >&2
    exit 1
elif [ "$1" = "break-lock" ]; then
    echo "Lock broken for $2"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$TEST_DIR/lock-handling-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository locked from previous session, breaking lock"
    echo "$output" | grep -q "Lock broken - next backup will proceed normally"

    # Verify break-lock was called
    grep -q "break-lock" "$BORG_COMMANDS_FILE"
}

# Test: Lock is broken when "Lock.*by.*PID" error occurs
@test "breaks remote lock when 'Lock by PID' error" {
    create_lock_handling_test_script

    # Create mock borg that returns PID lock error
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "$@" >> "$BORG_COMMANDS_FILE"
if [ "$1" = "list" ]; then
    echo "Lock held by PID 12345 on host backup-server" >&2
    exit 1
elif [ "$1" = "break-lock" ]; then
    echo "Lock broken for $2"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$TEST_DIR/lock-handling-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository locked from previous session, breaking lock"
    echo "$output" | grep -q "Lock broken - next backup will resume from checkpoint"

    # Verify break-lock was called
    grep -q "break-lock" "$BORG_COMMANDS_FILE"
}

# Test: Local cache locks are cleaned
@test "clears local cache locks on lock error" {
    create_lock_handling_test_script

    # Create fake cache lock files
    touch "$TEST_DIR/borg/cache/lock.exclusive"
    touch "$TEST_DIR/borg/cache/lock.roster"

    # Create mock borg that returns lock error
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "Failed to create/acquire the lock" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$TEST_DIR/lock-handling-test.sh"
    [ "$status" -eq 0 ]

    # Cache locks should be deleted
    [ ! -f "$TEST_DIR/borg/cache/lock.exclusive" ]
    [ ! -f "$TEST_DIR/borg/cache/lock.roster" ]
}

# Test: Repository exists - no lock breaking needed
@test "does not break lock when repository accessible" {
    create_lock_handling_test_script

    # Create mock borg that succeeds
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "$@" >> "$BORG_COMMANDS_FILE"
if [ "$1" = "list" ]; then
    echo "backup-2024-01-01"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$TEST_DIR/lock-handling-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository already exists"

    # break-lock should NOT be called
    ! grep -q "break-lock" "$BORG_COMMANDS_FILE"
}
