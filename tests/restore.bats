#!/usr/bin/env bats

# Test restore.sh restore operations

setup() {
    # Path to the script under test
    RESTORE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/restore.sh"

    # Create temporary test directory
    TEST_DIR="/tmp/test-restore-$$"
    mkdir -p "$TEST_DIR/bin"

    # Set up environment
    export BORG_REPO="/tmp/test-repo-$$"
    export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
    # Clean up
    rm -rf "$TEST_DIR"
    unset BORG_REPO
}

# Test: List action (default)
@test "lists archives by default" {
    # Create mock borg
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "backup-2024-01-01_00-00-00    Mon, 2024-01-01 00:00:00"
    echo "backup-2024-01-02_00-00-00    Tue, 2024-01-02 00:00:00"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Listing all archives"
    echo "$output" | grep -q "backup-2024-01-01_00-00-00"
    echo "$output" | grep -q "backup-2024-01-02_00-00-00"
}

@test "list action explicitly" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "BORG_LIST: Repository $2"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" list
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_LIST: Repository $BORG_REPO"
}

# Test: Info action
@test "shows archive info when archive specified" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
    echo "BORG_INFO: Archive $2"
    echo "Archive name: backup-test"
    echo "Archive size: 1.2 GB"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" info backup-test
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Archive information"
    echo "$output" | grep -q "BORG_INFO: Archive ${BORG_REPO}::backup-test"
}

@test "info action requires archive name" {
    run sh "$RESTORE_SCRIPT" info
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Archive name required for info action"
    echo "$output" | grep -q "Usage:.*info <archive-name>"
}

# Test: Extract action
@test "extracts archive to default path" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "extract" ]; then
    echo "BORG_EXTRACT: $@"
    echo "Extracting file1.txt"
    echo "Extracting file2.txt"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Extracting archive: backup-test"
    echo "$output" | grep -q "Destination: ."
    echo "$output" | grep -q "BORG_EXTRACT:.*--list.*${BORG_REPO}::backup-test.*--target ."
    echo "$output" | grep -q "✅ Extraction completed!"
}

@test "extracts archive to specified path" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "extract" ]; then
    for arg in "$@"; do
        case "$arg" in
            --target) next_is_target=1 ;;
            *)
                if [ "$next_is_target" = "1" ]; then
                    echo "TARGET_PATH: $arg"
                    next_is_target=0
                fi
                ;;
        esac
    done
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /custom/restore/path
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Destination: /custom/restore/path"
    echo "$output" | grep -q "TARGET_PATH: /custom/restore/path"
}

@test "extract action requires archive name" {
    run sh "$RESTORE_SCRIPT" extract
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Archive name required for extract action"
    echo "$output" | grep -q "Usage:.*extract <archive-name>"
}

# Test: Mount action
@test "mounts entire repository when no archive specified" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "mount" ]; then
    echo "BORG_MOUNT: Repo $2 to $3"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" mount
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Mounting entire repository at: ."
    echo "$output" | grep -q "BORG_MOUNT: Repo $BORG_REPO to ."
    echo "$output" | grep -q "✅ Mounted! Access files at: ."
    echo "$output" | grep -q "To unmount: borg umount ."
}

@test "mounts specific archive when specified" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "mount" ]; then
    echo "BORG_MOUNT: Archive $2 to $3"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" mount backup-test /mnt/backup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Mounting archive: backup-test at: /mnt/backup"
    echo "$output" | grep -q "BORG_MOUNT: Archive ${BORG_REPO}::backup-test to /mnt/backup"
    echo "$output" | grep -q "✅ Mounted! Access files at: /mnt/backup"
    echo "$output" | grep -q "To unmount: borg umount /mnt/backup"
}

# Test: Check action
@test "checks repository integrity" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    echo "BORG_CHECK: $@"
    echo "Checking segments..."
    echo "Checking archives..."
    echo "All checks passed"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Checking repository integrity"
    echo "$output" | grep -q "BORG_CHECK:.*--progress.*$BORG_REPO"
    echo "$output" | grep -q "All checks passed"
    echo "$output" | grep -q "✅ Repository check completed!"
}

# Test: Invalid action shows usage
@test "shows usage for invalid action" {
    run sh "$RESTORE_SCRIPT" invalid
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Usage:.*<action>"
    echo "$output" | grep -q "Actions:"
    echo "$output" | grep -q "list"
    echo "$output" | grep -q "info"
    echo "$output" | grep -q "extract"
    echo "$output" | grep -q "mount"
    echo "$output" | grep -q "check"
    echo "$output" | grep -q "Examples:"
}

# Test: Repository path is displayed
@test "displays repository path in header" {
    export BORG_REPO="/custom/repo/path"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" list
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository: /custom/repo/path"
}

# Test: Extract with --list flag
@test "extract uses --list flag for verbose output" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "extract" ]; then
    for arg in "$@"; do
        if [ "$arg" = "--list" ]; then
            echo "LIST_FLAG_FOUND"
        fi
    done
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "LIST_FLAG_FOUND"
}

# Test: Check with --progress flag
@test "check uses --progress flag" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "check" ]; then
    for arg in "$@"; do
        if [ "$arg" = "--progress" ]; then
            echo "PROGRESS_FLAG_FOUND"
        fi
    done
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PROGRESS_FLAG_FOUND"
}

# Test: Handle borg command failures
@test "handles borg list failure" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "ERROR: Repository not found"
    exit 2
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" list
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "ERROR: Repository not found"
}

@test "handles borg extract failure" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "extract" ]; then
    echo "ERROR: Archive not found"
    exit 2
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "ERROR: Archive not found"
    echo "$output" | grep -qv "✅ Extraction completed!"
}