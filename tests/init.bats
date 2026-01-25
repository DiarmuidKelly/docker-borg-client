#!/usr/bin/env bats

# Test init.sh repository initialization

setup() {
    # Path to the script under test
    INIT_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/init.sh"

    # Create temporary test directory
    TEST_DIR="/tmp/test-init-$$"
    mkdir -p "$TEST_DIR/bin"
    mkdir -p "$TEST_DIR/borg/config"

    # Set up environment
    export BORG_REPO="/tmp/test-repo-$$"
    export BORG_PASSPHRASE="test-passphrase"
    export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
    # Clean up
    rm -rf "$TEST_DIR"
    rm -rf "$BORG_REPO"
    unset BORG_REPO
    unset BORG_PASSPHRASE
}

# Test: Successful repository initialization
@test "initializes repository successfully" {
    # Create mock borg that succeeds
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "init" ]; then
    # $2 is --encryption=repokey, extract just the value
    encryption=$(echo "$2" | sed 's/--encryption=//')
    echo "BORG: Initializing repository with encryption=$encryption"
    echo "BORG: Repository: $3"
    exit 0
elif [ "$1" = "key" ] && [ "$2" = "export" ]; then
    echo "BORG: Exporting key to $4"
    echo "EXPORTED_KEY_DATA" > "$4"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    # Replace /borg/config path for testing
    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Initializing Borg Repository"
    echo "$output" | grep -q "Repository: $BORG_REPO"
    echo "$output" | grep -q "BORG: Initializing repository with encryption=repokey"
    echo "$output" | grep -q "Repository initialized successfully!"
    echo "$output" | grep -q "Exporting repository key"
    echo "$output" | grep -q "CRITICAL: BACKUP THESE CREDENTIALS"
    [ -f "$TEST_DIR/borg/config/repo-key.txt" ]
}

# Test: Repository initialization failure
@test "handles repository initialization failure" {
    # Create mock borg that fails on init
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "init" ]; then
    echo "ERROR: Repository already exists"
    exit 1
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Repository already exists"
}

# Test: Key export failure
@test "handles key export failure" {
    # Create mock borg that succeeds on init but fails on key export
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "init" ]; then
    echo "Repository initialized"
    exit 0
elif [ "$1" = "key" ] && [ "$2" = "export" ]; then
    echo "ERROR: Failed to export key"
    exit 1
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Repository initialized"
    echo "$output" | grep -q "ERROR: Failed to export key"
}

# Test: Correct borg commands are called
@test "calls borg with correct parameters" {
    # Create mock borg that logs all arguments
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_CMD: $@"
if [ "$1" = "init" ]; then
    exit 0
elif [ "$1" = "key" ]; then
    touch "$4"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_CMD: init --encryption=repokey $BORG_REPO"
    echo "$output" | grep -q "BORG_CMD: key export $BORG_REPO $TEST_DIR/borg/config/repo-key.txt"
}

# Test: Output includes security warnings
@test "displays security warnings about credentials" {
    # Create mock borg that succeeds
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "init" ]; then
    exit 0
elif [ "$1" = "key" ]; then
    touch "$4"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "CRITICAL: BACKUP THESE CREDENTIALS"
    echo "$output" | grep -q "Passphrase (from BORG_PASSPHRASE env var)"
    echo "$output" | grep -q "Save to password manager NOW"
    echo "$output" | grep -q "Repository Key:"
    echo "$output" | grep -q "Copy to password manager for disaster recovery"
    echo "$output" | grep -q "Without BOTH of these, your backups may be unrecoverable!"
}

# Test: Repository path is properly passed to borg
@test "uses BORG_REPO environment variable" {
    export BORG_REPO="/custom/repo/path"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "init" ]; then
    echo "REPO_PATH: $4"
    exit 0
elif [ "$1" = "key" ]; then
    echo "KEY_REPO_PATH: $3"
    touch "$4"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "REPO_PATH: /custom/repo/path"
    echo "$output" | grep -q "KEY_REPO_PATH: /custom/repo/path"
}

# Test: Creates key file with proper path
@test "creates key file in correct location" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "init" ]; then
    exit 0
elif [ "$1" = "key" ] && [ "$2" = "export" ]; then
    echo "TEST_KEY_CONTENT" > "$4"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    sed "s|/borg/config|$TEST_DIR/borg/config|g" "$INIT_SCRIPT" > "$TEST_DIR/init-test.sh"

    run sh "$TEST_DIR/init-test.sh"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/borg/config/repo-key.txt" ]
    [ "$(cat $TEST_DIR/borg/config/repo-key.txt)" = "TEST_KEY_CONTENT" ]
}