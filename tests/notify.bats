#!/usr/bin/env bats

# Test notify.sh - records job events to a persistent history file.
#
# It previously pushed to the TrueNAS API, which silently discarded every
# event (issue #33). The replacement must never fail the job that called it.

setup() {
    NOTIFY_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/notify.sh"

    TEST_DIR="/tmp/test-notify-$$"
    mkdir -p "$TEST_DIR"

    export HISTORY_FILE="$TEST_DIR/history.log"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset HISTORY_FILE HISTORY_MAX_LINES
}

# ---------- recording ----------

@test "records an event to the history file" {
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Borg Backup Successful" "Archive: backup-1, Duration: 206s"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Recorded: backup.success"

    [ -f "$HISTORY_FILE" ]
    grep -q "backup.success INFO Borg Backup Successful | Archive: backup-1, Duration: 206s" "$HISTORY_FILE"
}

@test "records a timestamp in ISO 8601 form" {
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Title" "Message"
    [ "$status" -eq 0 ]
    grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} " "$HISTORY_FILE"
}

@test "appends rather than overwriting" {
    sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "First" "one"
    sh "$NOTIFY_SCRIPT" "prune.success" "INFO" "Second" "two"
    sh "$NOTIFY_SCRIPT" "verify.failure" "CRITICAL" "Third" "three"

    [ "$(wc -l < "$HISTORY_FILE")" -eq 3 ]
    grep -q "First" "$HISTORY_FILE"
    grep -q "Second" "$HISTORY_FILE"
    grep -q "Third" "$HISTORY_FILE"
}

@test "records failures as well as successes" {
    run sh "$NOTIFY_SCRIPT" "verify.failure" "CRITICAL" "Borg Verification Failed" "Level: archives, Exit code: 2"
    [ "$status" -eq 0 ]
    grep -q "verify.failure CRITICAL Borg Verification Failed | Level: archives, Exit code: 2" "$HISTORY_FILE"
}

# Every event is recorded deliberately: a history that omitted successes could
# not answer "did the last backup work?"
@test "records events regardless of NOTIFY_EVENTS" {
    export NOTIFY_EVENTS="backup.failure"

    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Should still be recorded" "detail"
    [ "$status" -eq 0 ]
    grep -q "Should still be recorded" "$HISTORY_FILE"
    unset NOTIFY_EVENTS
}

@test "records events without requiring any TrueNAS configuration" {
    # The old transport exited early unless NOTIFY_TRUENAS_ENABLED=true
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "No config needed" "detail"
    [ "$status" -eq 0 ]
    grep -q "No config needed" "$HISTORY_FILE"
}

@test "keeps a multi-line message on one line" {
    run sh "$NOTIFY_SCRIPT" "backup.failure" "CRITICAL" "Failed" "line one
line two"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HISTORY_FILE")" -eq 1 ]
    grep -q "line one line two" "$HISTORY_FILE"
}

@test "creates the history directory if it does not exist" {
    export HISTORY_FILE="$TEST_DIR/nested/deeper/history.log"

    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Title" "Message"
    [ "$status" -eq 0 ]
    [ -f "$HISTORY_FILE" ]
}

# ---------- rolling cap ----------

@test "caps the history at HISTORY_MAX_LINES, dropping the oldest" {
    export HISTORY_MAX_LINES=5

    i=1
    while [ $i -le 8 ]; do
        sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "event-$i" "detail"
        i=$((i + 1))
    done

    [ "$(wc -l < "$HISTORY_FILE")" -eq 5 ]
    # Oldest dropped, newest kept
    ! grep -q "event-1 " "$HISTORY_FILE"
    ! grep -q "event-3 " "$HISTORY_FILE"
    grep -q "event-4 " "$HISTORY_FILE"
    grep -q "event-8 " "$HISTORY_FILE"
}

@test "leaves the history alone when under the cap" {
    export HISTORY_MAX_LINES=100

    sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "first" "detail"
    sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "second" "detail"

    [ "$(wc -l < "$HISTORY_FILE")" -eq 2 ]
    grep -q "first" "$HISTORY_FILE"
}

@test "does not leave a temporary file behind after trimming" {
    export HISTORY_MAX_LINES=2

    i=1
    while [ $i -le 5 ]; do
        sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "event-$i" "detail"
        i=$((i + 1))
    done

    [ ! -f "${HISTORY_FILE}.tmp" ]
}

# ---------- must never break the calling job ----------

@test "exits 0 when the history file cannot be written" {
    # A path that cannot be created
    export HISTORY_FILE="/proc/cannot/write/here/history.log"

    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Title" "Message"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "WARNING: cannot"
}

@test "exits 0 when the history file is not writable" {
    printf 'existing\n' > "$HISTORY_FILE"
    chmod 444 "$HISTORY_FILE"

    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "Title" "Message"
    [ "$status" -eq 0 ]

    chmod 644 "$HISTORY_FILE"
}

# ---------- argument validation ----------

@test "requires an event type" {
    run sh "$NOTIFY_SCRIPT" "" "INFO" "Title" "Message"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "requires EVENT_TYPE and EVENT_TITLE"
}

@test "requires a title" {
    run sh "$NOTIFY_SCRIPT" "backup.success" "INFO" "" "Message"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "requires EVENT_TYPE and EVENT_TITLE"
}

@test "accepts an empty message" {
    run sh "$NOTIFY_SCRIPT" "container.startup" "INFO" "Container Started"
    [ "$status" -eq 0 ]
    grep -q "container.startup INFO Container Started" "$HISTORY_FILE"
}
