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

    # borg is mocked here, so the real FUSE probe is irrelevant - skip it so
    # mount tests behave the same on hosts with and without /dev/fuse
    export RESTORE_SKIP_FUSE_CHECK=true

    # Keep the destination guard deterministic
    unset BACKUP_PATHS
}

teardown() {
    # Clean up
    rm -rf "$TEST_DIR"
    unset BORG_REPO
    unset RESTORE_SKIP_FUSE_CHECK
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
    echo "CWD: $(pwd)"
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
    echo "$output" | grep -q "BORG_EXTRACT:.*--list.*${BORG_REPO}::backup-test"
    echo "$output" | grep -q "✅ Extraction completed!"
}

@test "extracts archive to specified path" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "extract" ]; then
    echo "BORG_EXTRACT: $@"
    echo "CWD: $(pwd)"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /tmp/custom-restore-path
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Destination: /tmp/custom-restore-path"
    echo "$output" | grep -q "CWD: /tmp/custom-restore-path"
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

# Test: latest resolves the newest archive name
@test "latest prints the newest archive name" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "backup-2026-10-02_01-00-00"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" latest
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "backup-2026-10-02_01-00-00"
}

@test "latest uses --last 1 to resolve the archive" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "ARGS: $@"
echo "backup-newest"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" latest
    [ "$status" -eq 0 ]
    echo "$output" | grep -q -- "--last 1"
}

@test "latest fails clearly when repository has no archives" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" latest
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "no archives to resolve 'latest'"
}

# Test: archive name "latest" is resolved for other actions
@test "info resolves the literal name 'latest'" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "backup-resolved"
    exit 0
fi
if [ "$1" = "info" ]; then
    echo "BORG_INFO: $2"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" info latest
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_INFO: ${BORG_REPO}::backup-resolved"
}

# Test: files action lists archive contents
@test "files lists paths inside an archive" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "data/important.txt"
    echo "data/sub/nested.txt"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" files backup-test
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Files in archive: backup-test"
    echo "$output" | grep -q "data/important.txt"
    echo "$output" | grep -q "data/sub/nested.txt"
}

@test "files filters on a pattern when given" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "data/important.txt"
    echo "data/sub/nested.txt"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" files backup-test important
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Filtering on: important"
    echo "$output" | grep -q "data/important.txt"
    ! echo "$output" | grep -q "nested.txt"
}

@test "files action requires archive name" {
    run sh "$RESTORE_SCRIPT" files
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Archive name required for files action"
}

# Test: selective extract passes inner paths through to borg
@test "extract passes specific inner paths to borg" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_EXTRACT: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test "$TEST_DIR/out" data/important.txt data/other.txt
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Paths: data/important.txt data/other.txt"
    echo "$output" | grep -q "BORG_EXTRACT:.*backup-test data/important.txt data/other.txt"
}

# Test: dry-run verifies without writing
@test "dry-run uses --dry-run and writes nothing" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_ARGS: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" dry-run backup-test
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No files will be written"
    echo "$output" | grep -q "BORG_ARGS:.*--dry-run.*--list.*${BORG_REPO}::backup-test"
    echo "$output" | grep -q "✅ Dry-run completed"
}

@test "dry-run accepts specific inner paths" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_ARGS: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" dry-run backup-test data/important.txt
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Paths: data/important.txt"
    echo "$output" | grep -q "BORG_ARGS:.*backup-test data/important.txt"
}

@test "dry-run action requires archive name" {
    run sh "$RESTORE_SCRIPT" dry-run
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Archive name required for dry-run action"
}

# Test: fail-safe - never restore over the live source data
@test "extract refuses to write to /" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "refusing to extract at '/'"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract refuses a destination inside a backup source path" {
    export BACKUP_PATHS="/data/photos:/data/docs"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /data/photos/restore-here
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "refusing to extract to '/data/photos/restore-here'"
    echo "$output" | grep -q "inside backup source '/data/photos'"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract allows a destination outside all backup source paths" {
    export BACKUP_PATHS="/data/photos:/data/docs"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_EXTRACT: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test "$TEST_DIR/out"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✅ Extraction completed!"
}

# Regression: the guard only rejected the literal "/" and the empty string, so
# the default destination of "." slipped through. The image sets no WORKDIR, so
# `docker exec ... /scripts/restore.sh extract latest` ran with cwd=/ and
# recreated the archive tree over the live filesystem.
@test "extract refuses the default destination when the working directory is /" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh -c "cd / && sh '$RESTORE_SCRIPT' extract backup-test"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "refusing to extract at '/'"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract refuses a relative destination that resolves to /" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh -c "cd /tmp && sh '$RESTORE_SCRIPT' extract backup-test .."
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "refusing to extract at '/'"
    echo "$output" | grep -q "resolves to '/'"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract refuses a path with .. segments that lands in a backup source" {
    export BACKUP_PATHS="/data/photos"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /data/photos/sub/../other
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "inside backup source '/data/photos'"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract guard copes with a trailing slash in BACKUP_PATHS" {
    export BACKUP_PATHS="/data/photos/"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /data/photos/restore
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "inside backup source"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract refuses the backup source directory itself" {
    export BACKUP_PATHS="/data/photos"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test /data/photos
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "inside backup source"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "extract refuses everything when BACKUP_PATHS is /" {
    export BACKUP_PATHS="/"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test "$TEST_DIR/out"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "BACKUP_PATHS includes '/'"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

@test "files reports no matches without failing" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    echo "data/important.txt"
    exit 0
fi
exit 1
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" files backup-test nothing-matches-this
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No paths in backup-test match 'nothing-matches-this'"
    echo "$output" | grep -q "no leading slash"
}

@test "extract warns when the destination is not empty" {
    mkdir -p "$TEST_DIR/out"
    touch "$TEST_DIR/out/pre-existing.txt"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" extract backup-test "$TEST_DIR/out"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "WARNING: destination .* is not empty"
}

# Test: mount preflight fails clearly without FUSE bindings
@test "mount reports a clear error when FUSE bindings are missing" {
    unset RESTORE_SKIP_FUSE_CHECK

    # Shim python3 so the pyfuse3/llfuse import probe always fails
    cat > "$TEST_DIR/bin/python3" << 'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$TEST_DIR/bin/python3"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_SHOULD_NOT_RUN"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" mount latest /mnt/test
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "no FUSE bindings"
    echo "$output" | grep -q "borgbackup-fuse"
    ! echo "$output" | grep -q "BORG_SHOULD_NOT_RUN"
}

# Test: umount action
@test "umount unmounts the given path" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_UMOUNT: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" umount /mnt/backup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Unmounting: /mnt/backup"
    echo "$output" | grep -q "BORG_UMOUNT: umount /mnt/backup"
    echo "$output" | grep -q "✅ Unmounted!"
}

@test "umount action requires a mount path" {
    run sh "$RESTORE_SCRIPT" umount
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: Mount path required for umount action"
}

# Test: key-export action
@test "key-export exports the repository key to the default path" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_KEY: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" key-export
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_KEY: key export ${BORG_REPO} /borg/config/repo-key.txt"
    echo "$output" | grep -q "Store this with your passphrase"
}

@test "key-export accepts a custom output path" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo "BORG_KEY: $@"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$RESTORE_SCRIPT" key-export /tmp/my-key.txt
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BORG_KEY: key export ${BORG_REPO} /tmp/my-key.txt"
}

# Test: usage lists the new recovery actions
@test "usage documents the recovery actions" {
    run sh "$RESTORE_SCRIPT" invalid
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "latest"
    echo "$output" | grep -q "files"
    echo "$output" | grep -q "dry-run"
    echo "$output" | grep -q "umount"
    echo "$output" | grep -q "drill"
    echo "$output" | grep -q "key-export"
    echo "$output" | grep -q "may be given as 'latest'"
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