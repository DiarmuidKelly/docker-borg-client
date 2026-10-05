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
if [ "$1" = "check" ]; then
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
if [ "$1" = "check" ]; then
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
if [ "$1" = "check" ]; then
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
if [ "$1" = "check" ]; then
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
if [ "$1" = "check" ]; then
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
if [ "$1" = "check" ]; then
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
    echo "$output" | grep -q "CHECK_REPO: /custom/repo/path"
}

# Test: Duration included in notification
@test "duration included in notification" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
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

# Test: The lock is never broken (issue #59)
#
# This script used to run `borg break-lock` unconditionally, which deleted the
# repository and cache locks out from under a running backup; the backup then
# died at its next checkpoint with "bug in code, exclusive lock should exist
# here". No borg subcommand other than check may ever be invoked here.
@test "never breaks the repository lock" {
    export BORG_COMMANDS_FILE="$TEST_DIR/borg-commands.log"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "$1" >> "$BORG_COMMANDS_FILE"
if [ "$1" = "check" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]

    ! grep -q "break-lock" "$BORG_COMMANDS_FILE"
    grep -q "check" "$BORG_COMMANDS_FILE"
    # check is the only borg subcommand invoked
    [ "$(sort -u "$BORG_COMMANDS_FILE" | wc -l)" -eq 1 ]
}

# Test: A locked repository is a skip, not a failure
@test "skips rather than failing when the repository is locked" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "Failed to create/acquire the lock /repo/lock.exclusive (timeout)." >&2
    exit 2
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    # Nothing was checked, but nothing is known to be wrong either
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIPPED: repository is locked"
    echo "$output" | grep -q "does not break locks"
    ! echo "$output" | grep -q "Verification completed successfully"
    ! echo "$output" | grep -q "NOTIFY: verify.failure"
}

# Test: A skip is recorded, so a check that never runs stays visible
@test "records verify.skipped when the repository is locked" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "Lock.exclusive is held by PID 1234 on host abc." >&2
    exit 2
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "NOTIFY: verify.skipped WARNING"
}

# Test: A real corruption failure is not mistaken for a lock skip
@test "corruption failure is still a failure" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "Index object count mismatch. Finished full repository check, errors found." >&2
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
    ! echo "$output" | grep -q "SKIPPED"
}

# Test: Default lock wait is passed to borg check
@test "passes default lock wait to borg check" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_CHECK:.*--lock-wait 300"
    echo "$output" | grep -q "Lock wait: 300s"
}

# Test: VERIFY_LOCK_WAIT overrides the default
@test "VERIFY_LOCK_WAIT overrides the default lock wait" {
    export VERIFY_LOCK_WAIT="30"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_CHECK:.*--lock-wait 30"
}

# Test: A non-numeric lock wait is a configuration error, not a borg error
@test "non-numeric VERIFY_LOCK_WAIT exits with a configuration error" {
    export VERIFY_LOCK_WAIT="forever"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_CALLED: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "VERIFY_LOCK_WAIT must be a non-negative integer"
    ! echo "$output" | grep -q "BORG_CALLED"
}

# Test: Repository check skipped on archives day
@test "repository check skipped on archives day" {
    # Set archives day to today
    TODAY=$(date +%d | sed 's/^0//')
    export VERIFY_ARCHIVES_CRON_SCHEDULE="0 3 $TODAY * *"
    export VERIFY_LEVEL="repository"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_CALLED: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Skipping repository check - archives check runs today"
    # Borg should NOT be called
    ! echo "$output" | grep -q "BORG_CALLED"
}

# Test: Repository check runs on non-archives day
@test "repository check runs on non-archives day" {
    # Set archives day to a different day
    TODAY=$(date +%d | sed 's/^0//')
    if [ "$TODAY" = "1" ]; then
        ARCHIVES_DAY="2"
    else
        ARCHIVES_DAY="1"
    fi
    export VERIFY_ARCHIVES_CRON_SCHEDULE="0 3 $ARCHIVES_DAY * *"
    export VERIFY_LEVEL="repository"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "Skipping repository check"
    echo "$output" | grep -q "BORG_CHECK:"
}

# Test: Archives check always runs regardless of day
@test "archives check runs on any day" {
    # Set archives day to today
    TODAY=$(date +%d | sed 's/^0//')
    export VERIFY_ARCHIVES_CRON_SCHEDULE="0 3 $TODAY * *"
    export VERIFY_LEVEL="archives"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$VERIFY_SCRIPT" > "$TEST_DIR/verify-test.sh"

    run sh "$TEST_DIR/verify-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "Skipping"
    echo "$output" | grep -q "BORG_CHECK:.*--archives-only"
}
