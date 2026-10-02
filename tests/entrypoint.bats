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
    unset BORG_PASSPHRASE_FILE
    unset BORG_PASSCOMMAND
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

# Helper to create cron configuration test script
create_cron_test_script() {
    cat > "$TEST_DIR/cron-test.sh" << 'EOF'
#!/bin/sh
set -e

# Simulate defaults (no defaults for verify schedules)
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * 0}"
VERIFY_ENABLED="${VERIFY_ENABLED:-false}"

# Create crontabs directory
mkdir -p /tmp/test-crontabs-$$

# Set up cron job
echo "$CRON_SCHEDULE /scripts/backup.sh >> /proc/1/fd/1 2>&1" > /tmp/test-crontabs-$$/root
echo "Cron job configured"

# Set up verification cron jobs if enabled
if [ "$VERIFY_ENABLED" = "true" ]; then
    if [ -n "$VERIFY_REPO_CRON_SCHEDULE" ]; then
        echo "$VERIFY_REPO_CRON_SCHEDULE VERIFY_LEVEL=repository /scripts/verify.sh >> /proc/1/fd/1 2>&1" >> /tmp/test-crontabs-$$/root
        echo "Repository verification cron configured: $VERIFY_REPO_CRON_SCHEDULE"
    fi
    if [ -n "$VERIFY_ARCHIVES_CRON_SCHEDULE" ]; then
        echo "$VERIFY_ARCHIVES_CRON_SCHEDULE VERIFY_LEVEL=archives /scripts/verify.sh >> /proc/1/fd/1 2>&1" >> /tmp/test-crontabs-$$/root
        echo "Archives verification cron configured: $VERIFY_ARCHIVES_CRON_SCHEDULE"
    fi
fi

# Set up restore drill cron if enabled
if [ "${RESTORE_DRILL_ENABLED:-false}" = "true" ]; then
    if [ -n "$RESTORE_DRILL_CRON_SCHEDULE" ]; then
        echo "$RESTORE_DRILL_CRON_SCHEDULE /scripts/restore-drill.sh >> /proc/1/fd/1 2>&1" >> /tmp/test-crontabs-$$/root
        echo "Restore drill cron configured: $RESTORE_DRILL_CRON_SCHEDULE"
    else
        echo "RESTORE_DRILL_ENABLED=true but RESTORE_DRILL_CRON_SCHEDULE is not set - drills will only run on demand"
    fi
fi

# Output the crontab for verification
cat /tmp/test-crontabs-$$/root
rm -rf /tmp/test-crontabs-$$
EOF
    chmod +x "$TEST_DIR/cron-test.sh"
}

# Runs the REAL entrypoint.sh with absolute paths redirected into TEST_DIR, so
# the banner, preflight call and cron wiring are covered as actually shipped
# rather than re-simulated (which can silently drift from the real script).
create_real_entrypoint_test() {
    mkdir -p "$TEST_DIR/crontabs" "$TEST_DIR/scripts"
    printf '9.9.9\n' > "$TEST_DIR/VERSION"

    for s in notify.sh backup.sh init.sh preflight.sh; do
        cat > "$TEST_DIR/scripts/$s" << EOF
#!/bin/sh
echo "CALLED: $s \$*"
exit 0
EOF
        chmod +x "$TEST_DIR/scripts/$s"
    done

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
case "$1" in
  list) exit 0 ;;
  --version) echo "borg 1.4.4-test" ;;
  key) echo "key exported" ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    # crond would block in the foreground; make it return instead
    cat > "$TEST_DIR/bin/crond" << 'EOF'
#!/bin/sh
echo "CROND STARTED: $*"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/crond"

    sed -e "s|/scripts/|$TEST_DIR/scripts/|g" \
        -e "s|/etc/crontabs/root|$TEST_DIR/crontabs/root|g" \
        -e "s|/borg/config|$TEST_DIR/borg/config|g" \
        -e "s|cat /VERSION|cat $TEST_DIR/VERSION|g" \
        "${BATS_TEST_DIRNAME}/../entrypoint.sh" > "$TEST_DIR/entrypoint-test.sh"
    chmod +x "$TEST_DIR/entrypoint-test.sh"
}

# ---------- startup banner (issue #40) ----------

@test "startup banner prints version, borg version and licence" {
    create_real_entrypoint_test
    export AUTO_INIT="false"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Version: 9.9.9"
    echo "$output" | grep -q "Borg: borg 1.4.4-test"
    echo "$output" | grep -q "Licence: GPL-3.0"
    echo "$output" | grep -q "Started:"
}

# ---------- preflight wiring ----------

@test "preflight runs on startup by default" {
    create_real_entrypoint_test
    export AUTO_INIT="false"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "CALLED: preflight.sh"
}

@test "preflight can be disabled with PREFLIGHT_ENABLED=false" {
    create_real_entrypoint_test
    export AUTO_INIT="false"
    export PREFLIGHT_ENABLED="false"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "CALLED: preflight.sh"
    unset PREFLIGHT_ENABLED
}

@test "container does not start when preflight exits non-zero" {
    create_real_entrypoint_test
    export AUTO_INIT="false"

    cat > "$TEST_DIR/scripts/preflight.sh" << 'EOF'
#!/bin/sh
echo "PREFLIGHT_STRICT=true - refusing to start"
exit 1
EOF
    chmod +x "$TEST_DIR/scripts/preflight.sh"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 1 ]
    ! echo "$output" | grep -q "CROND STARTED"
}

# ---------- restore drill cron on the real entrypoint ----------

@test "real entrypoint configures the restore drill cron when enabled" {
    create_real_entrypoint_test
    export AUTO_INIT="false"
    export RESTORE_DRILL_ENABLED="true"
    export RESTORE_DRILL_CRON_SCHEDULE="0 4 1 1,4,7,10 *"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Restore drill cron configured: 0 4 1 1,4,7,10 \*"
    grep -q "restore-drill.sh" "$TEST_DIR/crontabs/root"
    unset RESTORE_DRILL_ENABLED RESTORE_DRILL_CRON_SCHEDULE
}

@test "real entrypoint warns when drills are enabled without a schedule" {
    create_real_entrypoint_test
    export AUTO_INIT="false"
    export RESTORE_DRILL_ENABLED="true"
    unset RESTORE_DRILL_CRON_SCHEDULE

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "drills will only run on demand"
    ! grep -q "restore-drill.sh" "$TEST_DIR/crontabs/root"
    unset RESTORE_DRILL_ENABLED
}

@test "real entrypoint does not configure a drill cron by default" {
    create_real_entrypoint_test
    export AUTO_INIT="false"
    unset RESTORE_DRILL_ENABLED

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "Restore drill cron configured"
    ! grep -q "restore-drill.sh" "$TEST_DIR/crontabs/root"
}

# ---------- drill cron via the simulated script ----------

@test "restore drill cron configured when enabled with a schedule" {
    create_cron_test_script
    export RESTORE_DRILL_ENABLED="true"
    export RESTORE_DRILL_CRON_SCHEDULE="0 4 1 1,4,7,10 *"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Restore drill cron configured"
    echo "$output" | grep -q "/scripts/restore-drill.sh"
    unset RESTORE_DRILL_ENABLED RESTORE_DRILL_CRON_SCHEDULE
}

@test "restore drill cron NOT configured when RESTORE_DRILL_ENABLED is false" {
    create_cron_test_script
    export RESTORE_DRILL_ENABLED="false"
    export RESTORE_DRILL_CRON_SCHEDULE="0 4 1 1,4,7,10 *"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "Restore drill cron configured"
    ! echo "$output" | grep -q "restore-drill.sh"
    unset RESTORE_DRILL_ENABLED RESTORE_DRILL_CRON_SCHEDULE
}

# Test: Both verification crons configured when both schedules set
@test "both verification crons configured when both schedules set" {
    create_cron_test_script
    export VERIFY_ENABLED="true"
    export VERIFY_REPO_CRON_SCHEDULE="0 3 * * 0"
    export VERIFY_ARCHIVES_CRON_SCHEDULE="0 3 1 * *"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository verification cron configured"
    echo "$output" | grep -q "Archives verification cron configured"
    echo "$output" | grep -q "VERIFY_LEVEL=repository /scripts/verify.sh"
    echo "$output" | grep -q "VERIFY_LEVEL=archives /scripts/verify.sh"
}

# Test: Verification cron NOT configured when VERIFY_ENABLED=false
@test "verification cron NOT configured when VERIFY_ENABLED=false" {
    create_cron_test_script
    export VERIFY_ENABLED="false"
    export VERIFY_REPO_CRON_SCHEDULE="0 3 * * 0"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "verification cron configured"
    ! echo "$output" | grep -q "/scripts/verify.sh"
}

# Test: No verification crons when no schedules set
@test "no verification crons when no schedules set" {
    create_cron_test_script
    export VERIFY_ENABLED="true"
    unset VERIFY_REPO_CRON_SCHEDULE
    unset VERIFY_ARCHIVES_CRON_SCHEDULE

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "verification cron configured"
    ! echo "$output" | grep -q "/scripts/verify.sh"
}

# Test: Only repo verification when only repo schedule set
@test "only repo verification when only repo schedule set" {
    create_cron_test_script
    export VERIFY_ENABLED="true"
    export VERIFY_REPO_CRON_SCHEDULE="0 3 * * 0"
    unset VERIFY_ARCHIVES_CRON_SCHEDULE

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository verification cron configured"
    ! echo "$output" | grep -q "Archives verification cron configured"
    echo "$output" | grep -q "VERIFY_LEVEL=repository /scripts/verify.sh"
    ! echo "$output" | grep -q "VERIFY_LEVEL=archives /scripts/verify.sh"
}

# Test: Only archives verification when only archives schedule set
@test "only archives verification when only archives schedule set" {
    create_cron_test_script
    export VERIFY_ENABLED="true"
    unset VERIFY_REPO_CRON_SCHEDULE
    export VERIFY_ARCHIVES_CRON_SCHEDULE="0 3 1 * *"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "Repository verification cron configured"
    echo "$output" | grep -q "Archives verification cron configured"
    ! echo "$output" | grep -q "VERIFY_LEVEL=repository /scripts/verify.sh"
    echo "$output" | grep -q "VERIFY_LEVEL=archives /scripts/verify.sh"
}

# Test: Custom repository verification schedule is used
@test "custom repository verification schedule is used" {
    create_cron_test_script
    export VERIFY_ENABLED="true"
    export VERIFY_REPO_CRON_SCHEDULE="0 4 * * 1"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "0 4 \* \* 1 VERIFY_LEVEL=repository /scripts/verify.sh"
}

# Test: Custom archives verification schedule is used
@test "custom archives verification schedule is used" {
    create_cron_test_script
    export VERIFY_ENABLED="true"
    export VERIFY_ARCHIVES_CRON_SCHEDULE="0 5 15 * *"

    run sh "$TEST_DIR/cron-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "0 5 15 \* \* VERIFY_LEVEL=archives /scripts/verify.sh"
}

# Helper to create passphrase-resolution test script (mirrors entrypoint.sh logic)
create_passphrase_test_script() {
    cat > "$TEST_DIR/passphrase-test.sh" << 'EOF'
#!/bin/sh
set -e

# Support the Docker secret convention: read the passphrase from a mounted file
if [ -n "${BORG_PASSPHRASE_FILE:-}" ] && [ -f "$BORG_PASSPHRASE_FILE" ]; then
    BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
    export BORG_PASSPHRASE
fi

# A passphrase must be available via one of three mechanisms
if [ -z "${BORG_PASSPHRASE:-}" ] && [ -z "${BORG_PASSCOMMAND:-}" ]; then
    echo "ERROR: a passphrase is required"
    exit 1
fi

echo "RESOLVED_PASSPHRASE=${BORG_PASSPHRASE:-}"
echo "PASSPHRASE_OK"
EOF
    chmod +x "$TEST_DIR/passphrase-test.sh"
}

# Test: BORG_PASSPHRASE env var is accepted (existing behaviour)
@test "accepts BORG_PASSPHRASE env var" {
    create_passphrase_test_script
    export BORG_PASSPHRASE="env-passphrase"
    unset BORG_PASSPHRASE_FILE
    unset BORG_PASSCOMMAND

    run sh "$TEST_DIR/passphrase-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASSPHRASE_OK"
    echo "$output" | grep -q "RESOLVED_PASSPHRASE=env-passphrase"
}

# Test: BORG_PASSPHRASE_FILE is read from disk
@test "reads passphrase from BORG_PASSPHRASE_FILE" {
    create_passphrase_test_script
    unset BORG_PASSPHRASE
    unset BORG_PASSCOMMAND
    printf 'file-passphrase' > "$TEST_DIR/passphrase.secret"
    export BORG_PASSPHRASE_FILE="$TEST_DIR/passphrase.secret"

    run sh "$TEST_DIR/passphrase-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASSPHRASE_OK"
    echo "$output" | grep -q "RESOLVED_PASSPHRASE=file-passphrase"
}

# Test: BORG_PASSCOMMAND alone satisfies validation (no passphrase in env)
@test "accepts BORG_PASSCOMMAND without BORG_PASSPHRASE" {
    create_passphrase_test_script
    unset BORG_PASSPHRASE
    unset BORG_PASSPHRASE_FILE
    export BORG_PASSCOMMAND="cat /run/secrets/passphrase"

    run sh "$TEST_DIR/passphrase-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASSPHRASE_OK"
    # Passphrase is intentionally NOT in the env - borg resolves it via the command
    echo "$output" | grep -q "RESOLVED_PASSPHRASE=$"
}

# Test: fails when no passphrase mechanism is provided
@test "fails when no passphrase mechanism is set" {
    create_passphrase_test_script
    unset BORG_PASSPHRASE
    unset BORG_PASSPHRASE_FILE
    unset BORG_PASSCOMMAND

    run sh "$TEST_DIR/passphrase-test.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "a passphrase is required"
}

# Test: BORG_PASSPHRASE_FILE takes precedence over BORG_PASSPHRASE env var
# Regression: a missing passphrase file was silently ignored. With a leftover
# BORG_PASSPHRASE still set, backups kept working from the env var - defeating
# the point of using a file - and with it unset the error never mentioned the
# unreadable file.
@test "fails when BORG_PASSPHRASE_FILE points at a missing file" {
    create_real_entrypoint_test
    export AUTO_INIT="false"
    export BORG_PASSPHRASE_FILE="$TEST_DIR/not-mounted"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "BORG_PASSPHRASE_FILE is set to '$TEST_DIR/not-mounted' but that file does not exist"
    ! echo "$output" | grep -q "CROND STARTED"
    unset BORG_PASSPHRASE_FILE
}

@test "does not silently fall back to BORG_PASSPHRASE when the file is missing" {
    create_real_entrypoint_test
    export AUTO_INIT="false"
    export BORG_PASSPHRASE="leftover-from-old-config"
    export BORG_PASSPHRASE_FILE="$TEST_DIR/not-mounted"

    run sh "$TEST_DIR/entrypoint-test.sh"
    [ "$status" -eq 1 ]
    ! echo "$output" | grep -q "CROND STARTED"
    unset BORG_PASSPHRASE_FILE
}

@test "BORG_PASSPHRASE_FILE overrides BORG_PASSPHRASE env var" {
    create_passphrase_test_script
    export BORG_PASSPHRASE="env-passphrase"
    printf 'file-passphrase' > "$TEST_DIR/passphrase.secret"
    export BORG_PASSPHRASE_FILE="$TEST_DIR/passphrase.secret"
    unset BORG_PASSCOMMAND

    run sh "$TEST_DIR/passphrase-test.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RESOLVED_PASSPHRASE=file-passphrase"
}
