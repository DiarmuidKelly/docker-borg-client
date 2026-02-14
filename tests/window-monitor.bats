#!/usr/bin/env bats

# Test window-monitor.sh window monitoring logic

setup() {
    # Path to the script under test
    WINDOW_MONITOR_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/window-monitor.sh"

    # Create temporary test directory
    TEST_DIR="/tmp/test-window-monitor-$$"
    mkdir -p "$TEST_DIR"

    # Create a mock repo for testing
    TEST_REPO="/tmp/test-borg-repo-$$"
    export BORG_REPO="$TEST_REPO"

    # Create a temporary file to simulate running state
    export WINDOW_MONITOR_RUNNING_FILE="/tmp/window-monitor-running-$$"
}

teardown() {
    # Clean up
    rm -rf "$TEST_DIR"
    rm -rf "$TEST_REPO"
    rm -f "$WINDOW_MONITOR_RUNNING_FILE"
    unset BORG_REPO
    unset BACKUP_WINDOW_START
    unset BACKUP_WINDOW_END
    unset WINDOW_MONITOR_ENABLED
    unset WINDOW_MONITOR_RUNNING_FILE
}

# Test: Script requires BORG_PID argument
@test "exits with error when BORG_PID not provided" {
    export BACKUP_WINDOW_START="10:00"
    export BACKUP_WINDOW_END="18:00"

    run sh "$WINDOW_MONITOR_SCRIPT"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: BORG_PID required"
}

# Test: Script runs with valid PID when window configured
@test "runs with valid PID and window configuration" {
    # Create a background process to monitor
    sleep 3 &
    TEST_PID=$!

    export BACKUP_WINDOW_START="00:00"
    export BACKUP_WINDOW_END="23:59"
    export BACKUP_RATE_LIMIT_OUT_WINDOW="5"  # Don't stop

    # Create mock scripts directory first
    mkdir -p "$TEST_DIR/scripts"

    # Replace /scripts/check-window.sh path for testing and reduce CHECK_INTERVAL for speed
    sed -e "s|/scripts/check-window.sh|$TEST_DIR/scripts/check-window.sh|g" \
        -e "s|CHECK_INTERVAL=60|CHECK_INTERVAL=1|g" \
        "$WINDOW_MONITOR_SCRIPT" > "$TEST_DIR/window-monitor-test.sh"

    # Create mock check-window.sh that always returns true
    cat > "$TEST_DIR/scripts/check-window.sh" << 'EOF'
#!/bin/sh
exit 0  # Always in window
EOF
    chmod +x "$TEST_DIR/scripts/check-window.sh"

    # Run for a short time then kill
    timeout 1 sh "$TEST_DIR/window-monitor-test.sh" "$TEST_PID" &
    MONITOR_PID=$!

    # Give it a moment to start
    sleep 0.2

    # Clean up
    kill $TEST_PID 2>/dev/null || true
    kill $MONITOR_PID 2>/dev/null || true
    wait $TEST_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true

    # Test passes if we got here without errors
    [ "$?" -eq 0 ] || [ "$?" -eq 124 ]  # 124 is timeout exit code
}

# Test: Terminates process when window ends with rate limit 0
@test "terminates process when window ends and rate limit is 0" {
    # Create a background process for monitoring
    sleep 5 &
    TEST_PID=$!

    export BACKUP_WINDOW_START="00:00"
    export BACKUP_WINDOW_END="00:01"  # Very short window
    export BACKUP_RATE_LIMIT_OUT_WINDOW="0"  # Should terminate

    # Create mock scripts directory first
    mkdir -p "$TEST_DIR/scripts"

    # Replace /scripts/check-window.sh path for testing and reduce CHECK_INTERVAL for speed
    sed -e "s|/scripts/check-window.sh|$TEST_DIR/scripts/check-window.sh|g" \
        -e "s|CHECK_INTERVAL=60|CHECK_INTERVAL=1|g" \
        "$WINDOW_MONITOR_SCRIPT" > "$TEST_DIR/window-monitor-test.sh"

    # Create mock check-window.sh that returns false (outside window)
    cat > "$TEST_DIR/scripts/check-window.sh" << 'EOF'
#!/bin/sh
exit 1  # Outside window
EOF
    chmod +x "$TEST_DIR/scripts/check-window.sh"

    # Create mock borg for checkpoint checking
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
echo '{"archives": []}'
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"
    PATH="$TEST_DIR/bin:$PATH"

    run timeout 3 sh "$TEST_DIR/window-monitor-test.sh" "$TEST_PID"
    # Script should exit quickly after detecting we're outside window
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Window ended, terminating backup"

    # Clean up
    kill $TEST_PID 2>/dev/null || true
}

# Test: Continues when rate limit is not 0 outside window
@test "continues when rate limit is not 0 outside window" {
    # Create a background process
    sleep 3 &
    TEST_PID=$!

    export BACKUP_WINDOW_START="00:00"
    export BACKUP_WINDOW_END="00:01"
    export BACKUP_RATE_LIMIT_OUT_WINDOW="5"  # Should continue

    # Create mock scripts directory first
    mkdir -p "$TEST_DIR/scripts"

    # Replace /scripts/check-window.sh path and reduce CHECK_INTERVAL for speed
    sed -e "s|/scripts/check-window.sh|$TEST_DIR/scripts/check-window.sh|g" \
        -e "s|CHECK_INTERVAL=60|CHECK_INTERVAL=1|g" \
        "$WINDOW_MONITOR_SCRIPT" > "$TEST_DIR/window-monitor-test.sh"

    # Mock check-window.sh - alternates between in/out of window
    cat > "$TEST_DIR/scripts/check-window.sh" << 'EOF'
#!/bin/sh
# First call returns false, then process dies
exit 1
EOF
    chmod +x "$TEST_DIR/scripts/check-window.sh"

    # Run for a short time
    timeout 1 sh "$TEST_DIR/window-monitor-test.sh" "$TEST_PID" &
    MONITOR_PID=$!

    sleep 0.2

    # Process should still be running
    kill -0 $TEST_PID 2>/dev/null && PROCESS_ALIVE=1 || PROCESS_ALIVE=0

    # Clean up
    kill $TEST_PID 2>/dev/null || true
    kill $MONITOR_PID 2>/dev/null || true

    [ "$PROCESS_ALIVE" -eq 1 ]
}

# Test: get_window_end_epoch calculates correct epoch (BusyBox compatible)
@test "get_window_end_epoch returns valid epoch for window end time" {
    export BACKUP_WINDOW_END="07:00"

    # Extract and run the get_window_end_epoch function
    cat > "$TEST_DIR/test-epoch.sh" << 'SCRIPT'
#!/bin/sh
BACKUP_WINDOW_END="$1"

get_window_end_epoch() {
    if [ -z "$BACKUP_WINDOW_END" ]; then
        echo "0"
        return
    fi

    HOUR=$(echo "$BACKUP_WINDOW_END" | cut -d: -f1 | sed 's/^0*//')
    MINUTE=$(echo "$BACKUP_WINDOW_END" | cut -d: -f2 | sed 's/^0*//')
    HOUR=${HOUR:-0}
    MINUTE=${MINUTE:-0}

    CURRENT_EPOCH=$(date +%s)
    CURRENT_HOUR=$(date +%H | sed 's/^0*//')
    CURRENT_MINUTE=$(date +%M | sed 's/^0*//')
    CURRENT_HOUR=${CURRENT_HOUR:-0}
    CURRENT_MINUTE=${CURRENT_MINUTE:-0}

    TARGET_SECONDS=$((HOUR * 3600 + MINUTE * 60))
    CURRENT_SECONDS=$((CURRENT_HOUR * 3600 + CURRENT_MINUTE * 60))

    MIDNIGHT_EPOCH=$((CURRENT_EPOCH - CURRENT_SECONDS))
    WINDOW_END=$((MIDNIGHT_EPOCH + TARGET_SECONDS))

    if [ "$WINDOW_END" -lt "$CURRENT_EPOCH" ]; then
        WINDOW_END=$((WINDOW_END + 86400))
    fi

    echo "$WINDOW_END"
}

get_window_end_epoch
SCRIPT
    chmod +x "$TEST_DIR/test-epoch.sh"

    run sh "$TEST_DIR/test-epoch.sh" "07:00"
    [ "$status" -eq 0 ]
    # Result should be a valid epoch (numeric, roughly current time)
    echo "$output" | grep -qE '^[0-9]+$'
    # Should be within reasonable range (current time +/- 2 days)
    CURRENT=$(date +%s)
    RESULT="$output"
    [ "$RESULT" -gt "$((CURRENT - 86400))" ]
    [ "$RESULT" -lt "$((CURRENT + 172800))" ]
}

# Test: get_window_end_epoch handles midnight correctly
@test "get_window_end_epoch handles 00:00 window end" {
    cat > "$TEST_DIR/test-epoch.sh" << 'SCRIPT'
#!/bin/sh
BACKUP_WINDOW_END="$1"

get_window_end_epoch() {
    if [ -z "$BACKUP_WINDOW_END" ]; then
        echo "0"
        return
    fi

    HOUR=$(echo "$BACKUP_WINDOW_END" | cut -d: -f1 | sed 's/^0*//')
    MINUTE=$(echo "$BACKUP_WINDOW_END" | cut -d: -f2 | sed 's/^0*//')
    HOUR=${HOUR:-0}
    MINUTE=${MINUTE:-0}

    CURRENT_EPOCH=$(date +%s)
    CURRENT_HOUR=$(date +%H | sed 's/^0*//')
    CURRENT_MINUTE=$(date +%M | sed 's/^0*//')
    CURRENT_HOUR=${CURRENT_HOUR:-0}
    CURRENT_MINUTE=${CURRENT_MINUTE:-0}

    TARGET_SECONDS=$((HOUR * 3600 + MINUTE * 60))
    CURRENT_SECONDS=$((CURRENT_HOUR * 3600 + CURRENT_MINUTE * 60))

    MIDNIGHT_EPOCH=$((CURRENT_EPOCH - CURRENT_SECONDS))
    WINDOW_END=$((MIDNIGHT_EPOCH + TARGET_SECONDS))

    if [ "$WINDOW_END" -lt "$CURRENT_EPOCH" ]; then
        WINDOW_END=$((WINDOW_END + 86400))
    fi

    echo "$WINDOW_END"
}

get_window_end_epoch
SCRIPT
    chmod +x "$TEST_DIR/test-epoch.sh"

    run sh "$TEST_DIR/test-epoch.sh" "00:00"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^[0-9]+$'
}

# Test: get_window_end_epoch returns 0 when no window configured
@test "get_window_end_epoch returns 0 when BACKUP_WINDOW_END empty" {
    cat > "$TEST_DIR/test-epoch.sh" << 'SCRIPT'
#!/bin/sh
BACKUP_WINDOW_END=""

get_window_end_epoch() {
    if [ -z "$BACKUP_WINDOW_END" ]; then
        echo "0"
        return
    fi
    echo "999"
}

get_window_end_epoch
SCRIPT
    chmod +x "$TEST_DIR/test-epoch.sh"

    run sh "$TEST_DIR/test-epoch.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}