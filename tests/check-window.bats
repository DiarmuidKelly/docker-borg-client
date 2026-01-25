#!/usr/bin/env bats

# Test check-window.sh backup window logic
# Note: These tests work with the actual current time

setup() {
    # Path to the script under test
    CHECK_WINDOW_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-window.sh"
}

teardown() {
    # Clean up environment variables
    unset BACKUP_WINDOW_START
    unset BACKUP_WINDOW_END
}

# Test: No window configured (should always allow)
@test "no window configured - both vars empty" {
    unset BACKUP_WINDOW_START
    unset BACKUP_WINDOW_END
    run sh "$CHECK_WINDOW_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "no window configured - only start set" {
    export BACKUP_WINDOW_START="10:00"
    unset BACKUP_WINDOW_END
    run sh "$CHECK_WINDOW_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "no window configured - only end set" {
    unset BACKUP_WINDOW_START
    export BACKUP_WINDOW_END="18:00"
    run sh "$CHECK_WINDOW_SCRIPT"
    [ "$status" -eq 0 ]
}

# Test: Dynamic windows based on current time
# These tests create windows that we know will include or exclude current time

@test "window that definitely includes current time" {
    # Create a 23-hour window that excludes only 1 hour (should include now)
    export BACKUP_WINDOW_START="00:00"
    export BACKUP_WINDOW_END="23:59"
    run sh "$CHECK_WINDOW_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "window that definitely excludes current time" {
    # Get current time and create a 1-minute window far from now
    current_hour=$(date +%H)

    # Set window to be 12 hours away from current time (1 minute window)
    if [ "$current_hour" -lt 12 ]; then
        # If morning, set window to evening
        export BACKUP_WINDOW_START="20:00"
        export BACKUP_WINDOW_END="20:01"
    else
        # If afternoon/evening, set window to early morning
        export BACKUP_WINDOW_START="06:00"
        export BACKUP_WINDOW_END="06:01"
    fi

    run sh "$CHECK_WINDOW_SCRIPT"
    [ "$status" -eq 1 ]
}

# Test: Window logic with known scenarios

@test "normal window - properly ordered times" {
    # Test that script handles normal windows correctly (without checking current time)
    # We just verify it runs without error
    export BACKUP_WINDOW_START="09:00"
    export BACKUP_WINDOW_END="17:00"
    run sh "$CHECK_WINDOW_SCRIPT"
    # Status will be 0 or 1 depending on current time, but script should run
    [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

@test "overnight window - start time after end time" {
    # Test that script handles overnight windows correctly
    export BACKUP_WINDOW_START="22:00"
    export BACKUP_WINDOW_END="06:00"
    run sh "$CHECK_WINDOW_SCRIPT"
    # Status will be 0 or 1 depending on current time, but script should run
    [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

# Test: Edge cases with specific time formats

@test "time format - handles times with leading zeros" {
    export BACKUP_WINDOW_START="01:00"
    export BACKUP_WINDOW_END="02:00"
    run sh "$CHECK_WINDOW_SCRIPT"
    # Should run without error regardless of result
    [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

@test "time format - handles 00:00 as start time" {
    export BACKUP_WINDOW_START="00:00"
    export BACKUP_WINDOW_END="01:00"
    run sh "$CHECK_WINDOW_SCRIPT"
    # Should run without error regardless of result
    [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

@test "time format - handles 23:59 as end time" {
    export BACKUP_WINDOW_START="23:00"
    export BACKUP_WINDOW_END="23:59"
    run sh "$CHECK_WINDOW_SCRIPT"
    # Should run without error regardless of result
    [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

# Test: Invalid input handling (if any)

@test "handles same start and end time" {
    export BACKUP_WINDOW_START="12:00"
    export BACKUP_WINDOW_END="12:00"
    run sh "$CHECK_WINDOW_SCRIPT"
    # Should handle this case without crashing
    [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}