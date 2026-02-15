#!/usr/bin/env bats

# Test verify.sh repository integrity verification logic

setup() {
    # Path to the script under test
    VERIFY_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/verify.sh"

    # Create temporary test directory
    TEST_DIR="/tmp/test-verify-$$"
    mkdir -p "$TEST_DIR/bin"
    mkdir -p "$TEST_DIR/scripts"

    # Create mock notify.sh
    cat > "$TEST_DIR/scripts/notify.sh" << 'EOF'
#!/bin/sh
echo "NOTIFY: $1 $2 $3 $4"
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
    unset VERIFY_LEVEL
}

# Test: Default level (repository) verification succeeds
@test "default level (repository) verification succeeds" {
    # Create mock borg that succeeds
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    # Replace script paths in verify.sh for testing
    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Verifying Repository Integrity"
    echo "$output" | grep -q "Verification level: repository"
    echo "$output" | grep -q "BORG_CHECK:.*--repository-only"
    echo "$output" | grep -q "BORG_CHECK:.*--progress"
    echo "$output" | grep -q "Verification completed successfully"
    echo "$output" | grep -q "NOTIFY: verify.success INFO"
}

# Test: Archives level uses --archives-only
@test "archives level uses --archives-only flag" {
    export VERIFY_LEVEL="archives"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Verification level: archives"
    echo "$output" | grep -q "BORG_CHECK:.*--archives-only"
    echo "$output" | grep -q "BORG_CHECK:.*--progress"
}

# Test: Full level uses --verify-data
@test "full level uses --verify-data flag" {
    export VERIFY_LEVEL="full"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Verification level: full"
    echo "$output" | grep -q "Running full verification"
    echo "$output" | grep -q "BORG_CHECK:.*--verify-data"
    echo "$output" | grep -q "BORG_CHECK:.*--progress"
}

# Test: Invalid level exits with error
@test "invalid level exits with error" {
    export VERIFY_LEVEL="invalid"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Invalid VERIFY_LEVEL 'invalid'"
    echo "$output" | grep -q "Valid options: repository, archives, full"
}

# Test: Verification failure sends verify.failure notification
@test "verification failure sends verify.failure notification" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    echo "ERROR: Repository corruption detected"
    exit 2
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "Verification failed"
    echo "$output" | grep -q "NOTIFY: verify.failure CRITICAL"
}

# Test: Progress flag is always used
@test "progress flag is always used" {
    for level in repository archives full; do
        export VERIFY_LEVEL="$level"

        cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
        chmod +x "$TEST_DIR/bin/borg"

        sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

        run sh "$TEST_DIR/verify-test.sh"
        [ "$status" -eq 0 ]
        echo "$output" | grep -q "BORG_CHECK:.*--progress"
    done
}

# Test: Repository path passed correctly
@test "repository path passed correctly to borg check" {
    export BORG_REPO="/custom/repo/path"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    echo "BREAK_LOCK_REPO: $2"
    exit 0
elif [ "$1" = "check" ]; then
    # Last argument should be repository
    for arg in "$@"; do
        last_arg="$arg"
    done
    echo "CHECK_REPO: $last_arg"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BREAK_LOCK_REPO: /custom/repo/path"
    echo "$output" | grep -q "CHECK_REPO: /custom/repo/path"
}

# Test: Duration included in notification
@test "duration included in notification" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    sleep 1
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Duration:"
    echo "$output" | grep -q "NOTIFY: verify.success INFO Borg Verification Successful"
    # Check that duration is in the notification (4th argument)
    echo "$output" | grep -q "Duration:.*s"
}

# Test: Lock is broken before verification
@test "breaks lock before running verification" {
    export BORG_COMMANDS_FILE="$TEST_DIR/borg-commands.log"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "$1" >> "$BORG_COMMANDS_FILE"
if [ "$1" = "break-lock" ]; then
    exit 0
elif [ "$1" = "check" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]

    # Verify break-lock was called first
    head -1 "$BORG_COMMANDS_FILE" | grep -q "break-lock"
    # Verify check was called second
    tail -1 "$BORG_COMMANDS_FILE" | grep -q "check"
}
