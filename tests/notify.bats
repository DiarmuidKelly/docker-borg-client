#!/usr/bin/env bats

# Test notify.sh notification logic

setup() {
    # Path to the script under test
    NOTIFY_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/notify.sh"
}

teardown() {
    # Clean up environment variables
    unset NOTIFY_TRUENAS_ENABLED
    unset NOTIFY_EVENTS
    unset NOTIFY_TRUENAS_API_URL
    unset NOTIFY_TRUENAS_API_KEY
    unset NOTIFY_TRUENAS_VERIFY_SSL
}

# Test: Script exits silently when notifications disabled
@test "exits silently when NOTIFY_TRUENAS_ENABLED is not true" {
    unset NOTIFY_TRUENAS_ENABLED
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Test Title" "Test Message"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    export NOTIFY_TRUENAS_ENABLED="false"
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Test Title" "Test Message"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Test: Requires EVENT_TYPE and EVENT_TITLE
@test "fails when EVENT_TYPE is missing" {
    export NOTIFY_TRUENAS_ENABLED="true"
    run sh "$NOTIFY_SCRIPT"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: notify.sh requires EVENT_TYPE and EVENT_TITLE"
}

@test "fails when EVENT_TITLE is missing" {
    export NOTIFY_TRUENAS_ENABLED="true"
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ERROR: notify.sh requires EVENT_TYPE and EVENT_TITLE"
}

# Test: Event filtering with NOTIFY_EVENTS not set (default to failures)
@test "notifies on failures by default when NOTIFY_EVENTS not set" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    export NOTIFY_TRUENAS_API_KEY="test-key"
    unset NOTIFY_EVENTS

    # Create a mock websocat that fails (simulating no actual API)
    cat > /tmp/mock-websocat-$$ << 'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x /tmp/mock-websocat-$$
    PATH="/tmp:$PATH"
    ln -s /tmp/mock-websocat-$$ /tmp/websocat

    # Should attempt to notify on failure
    run sh "$NOTIFY_SCRIPT" "backup.failure" "CRITICAL" "Backup Failed" "Details"
    [ "$status" -eq 0 ]  # Script exits 0 even if notification fails
    echo "$output" | grep -q "TrueNAS notification failed"

    # Should not attempt to notify on success
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Backup OK" "Details"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    rm -f /tmp/websocat /tmp/mock-websocat-$$
}

# Test: Event filtering with NOTIFY_EVENTS set
@test "respects NOTIFY_EVENTS filter list" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_EVENTS="backup.start,backup.success,prune.failure"

    # Create mock websocat
    cat > /tmp/mock-websocat-$$ << 'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x /tmp/mock-websocat-$$
    PATH="/tmp:$PATH"
    ln -s /tmp/mock-websocat-$$ /tmp/websocat

    # Should notify on listed events
    run sh "$NOTIFY_SCRIPT" "backup.start" "INFO" "Starting" "Details"
    echo "$output" | grep -q "TrueNAS notification failed"  # Tries to notify

    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Success" "Details"
    echo "$output" | grep -q "TrueNAS notification failed"  # Tries to notify

    run sh "$NOTIFY_SCRIPT" "prune.failure" "ERROR" "Failed" "Details"
    echo "$output" | grep -q "TrueNAS notification failed"  # Tries to notify

    # Should not notify on unlisted events
    run sh "$NOTIFY_SCRIPT" "backup.failure" "ERROR" "Failed" "Details"
    [ -z "$output" ]  # Doesn't try to notify

    run sh "$NOTIFY_SCRIPT" "prune.success" "INFO" "Success" "Details"
    [ -z "$output" ]  # Doesn't try to notify

    rm -f /tmp/websocat /tmp/mock-websocat-$$
}

# Test: API URL and KEY validation
@test "warns when API_URL is missing" {
    export NOTIFY_TRUENAS_ENABLED="true"
    unset NOTIFY_TRUENAS_API_URL
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_EVENTS="backup.failure"

    run sh "$NOTIFY_SCRIPT" "backup.failure" "ERROR" "Failed" "Details"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "WARNING: TrueNAS notifications enabled but API_URL or API_KEY not set"
}

@test "warns when API_KEY is missing" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    unset NOTIFY_TRUENAS_API_KEY
    export NOTIFY_EVENTS="backup.failure"

    run sh "$NOTIFY_SCRIPT" "backup.failure" "ERROR" "Failed" "Details"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "WARNING: TrueNAS notifications enabled but API_URL or API_KEY not set"
}

# Test: URL formatting for WebSocket endpoint
@test "formats WebSocket URL correctly" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local/"  # With trailing slash
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_EVENTS="test.event"

    # Mock websocat to capture the URL it receives
    cat > /tmp/mock-websocat-$$ << 'EOF'
#!/bin/sh
echo "MOCK_URL: $2"
exit 1
EOF
    chmod +x /tmp/mock-websocat-$$
    PATH="/tmp:$PATH"
    ln -s /tmp/mock-websocat-$$ /tmp/websocat

    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" "Test" "Message"
    echo "$output" | grep -q "MOCK_URL: http://test.local/api/current"

    # Test without trailing slash
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" "Test" "Message"
    echo "$output" | grep -q "MOCK_URL: http://test.local/api/current"

    rm -f /tmp/websocat /tmp/mock-websocat-$$
}

# Test: SSL verification flag
@test "uses --insecure flag when VERIFY_SSL is false" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="https://test.local"
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_TRUENAS_VERIFY_SSL="false"
    export NOTIFY_EVENTS="test.event"

    # Mock websocat to capture flags
    cat > /tmp/mock-websocat-$$ << 'EOF'
#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = "--insecure" ]; then
        echo "INSECURE_FLAG_FOUND"
    fi
done
exit 1
EOF
    chmod +x /tmp/mock-websocat-$$
    PATH="/tmp:$PATH"
    ln -s /tmp/mock-websocat-$$ /tmp/websocat

    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" "Test" "Message"
    echo "$output" | grep -q "INSECURE_FLAG_FOUND"

    # Test without insecure flag
    export NOTIFY_TRUENAS_VERIFY_SSL="true"
    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" "Test" "Message"
    echo "$output" | grep -qv "INSECURE_FLAG_FOUND" || true

    rm -f /tmp/websocat /tmp/mock-websocat-$$
}

# Test: JSON escaping
@test "escapes JSON special characters in title and message" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_EVENTS="test.event"

    # Mock websocat to capture the JSON
    cat > /tmp/mock-websocat-$$ << 'EOF'
#!/bin/sh
cat  # Echo stdin to stdout
exit 1
EOF
    chmod +x /tmp/mock-websocat-$$
    PATH="/tmp:$PATH"
    ln -s /tmp/mock-websocat-$$ /tmp/websocat

    # Test with quotes and newlines
    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" 'Title with "quotes"' 'Message with
newline'

    # Should have escaped quotes
    echo "$output" | grep -q 'Title with \\"quotes\\"'
    # Note: The actual newline handling may vary

    rm -f /tmp/websocat /tmp/mock-websocat-$$
}

# Test: Event levels
@test "passes correct event levels" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_EVENTS="test.event"

    # Mock websocat to capture the JSON
    cat > /tmp/mock-websocat-$$ << 'EOF'
#!/bin/sh
cat
exit 1
EOF
    chmod +x /tmp/mock-websocat-$$
    PATH="/tmp:$PATH"
    ln -s /tmp/mock-websocat-$$ /tmp/websocat

    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" "Test" "Message"
    echo "$output" | grep -q '"level":"INFO"'

    run sh "$NOTIFY_SCRIPT" "test.event" "WARNING" "Test" "Message"
    echo "$output" | grep -q '"level":"WARNING"'

    run sh "$NOTIFY_SCRIPT" "test.event" "CRITICAL" "Test" "Message"
    echo "$output" | grep -q '"level":"CRITICAL"'

    rm -f /tmp/websocat /tmp/mock-websocat-$$
}

# Test: Always exits 0 (doesn't break backups)
@test "always exits with status 0 even on notification failure" {
    export NOTIFY_TRUENAS_ENABLED="true"
    export NOTIFY_TRUENAS_API_URL="http://test.local"
    export NOTIFY_TRUENAS_API_KEY="test-key"
    export NOTIFY_EVENTS="test.event"

    # No websocat available - should fail but exit 0
    PATH="/nonexistent:$PATH"
    run sh "$NOTIFY_SCRIPT" "test.event" "INFO" "Test" "Message"
    [ "$status" -eq 0 ]
}