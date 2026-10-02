#!/usr/bin/env bats

# Test restore-drill.sh - the automated restore drill that proves backups are
# actually recoverable, not merely structurally intact.

setup() {
    DRILL_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/restore-drill.sh"

    TEST_DIR="/tmp/test-drill-$$"
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/scripts" "$TEST_DIR/src/sub"

    # Mock notify.sh so notifications can be asserted on
    cat > "$TEST_DIR/scripts/notify.sh" << 'EOF'
#!/bin/sh
echo "NOTIFY: $1 $2 $3 $4"
exit 0
EOF
    chmod +x "$TEST_DIR/scripts/notify.sh"

    # Live source files. Paths inside an archive have no leading slash, so an
    # archive path of "tmp/test-drill-N/src/a.txt" maps to this real file -
    # which is what lets the drill compare restored bytes against the source.
    printf 'alpha content\n' > "$TEST_DIR/src/a.txt"
    printf 'beta content\n' > "$TEST_DIR/src/sub/b.txt"

    REL_A="${TEST_DIR#/}/src/a.txt"
    REL_B="${TEST_DIR#/}/src/sub/b.txt"

    # Flexible borg mock, driven by MOCK_* env vars
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
cmd="$1"; shift
case "$cmd" in
  list)
    if [ -n "$MOCK_LIST_FAIL" ]; then
        echo "$MOCK_LIST_MSG" >&2
        exit "$MOCK_LIST_FAIL"
    fi
    if printf '%s\n' "$@" | grep -q -- '--json-lines'; then
        cat "$MOCK_JSONL"
    else
        printf '%s\n' "$MOCK_ARCHIVE"
    fi
    ;;
  extract)
    if [ -n "$MOCK_EXTRACT_FAIL" ]; then
        echo "$MOCK_EXTRACT_MSG" >&2
        exit "$MOCK_EXTRACT_FAIL"
    fi
    skip_next=0
    for a in "$@"; do
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        case "$a" in
            --lock-wait) skip_next=1; continue ;;
            --*) continue ;;
            *::*) continue ;;
        esac
        if [ "$a" = "$MOCK_EXTRACT_SKIP" ]; then continue; fi
        mkdir -p "$(dirname "$a")"
        if [ -f "/$a" ] && [ -z "$MOCK_CORRUPT" ]; then
            cp "/$a" "$a"
        else
            printf 'different content\n' > "$a"
        fi
        echo "$a"
    done
    ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    export PATH="$TEST_DIR/bin:$PATH"
    export BORG_REPO="/tmp/test-repo-$$"
    export MOCK_ARCHIVE="backup-drill-1"
    export RESTORE_DRILL_TARGET="$TEST_DIR/restored"

    # Redirect /scripts/ to the mock directory, matching the other suites
    sed "s|/scripts/|$TEST_DIR/scripts/|g" "$DRILL_SCRIPT" > "$TEST_DIR/drill.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset BORG_REPO MOCK_ARCHIVE MOCK_JSONL MOCK_LIST_FAIL MOCK_LIST_MSG
    unset MOCK_EXTRACT_FAIL MOCK_EXTRACT_MSG MOCK_EXTRACT_SKIP MOCK_CORRUPT
    unset RESTORE_DRILL_PATHS RESTORE_DRILL_TARGET RESTORE_DRILL_SAMPLE_COUNT
    unset RESTORE_DRILL_ARCHIVE RESTORE_DRILL_KEEP RESTORE_DRILL_MAX_FILE_BYTES
}

# Write a --json-lines fixture describing an archive's contents
write_jsonl() {
    MOCK_JSONL="$TEST_DIR/archive.jsonl"
    export MOCK_JSONL
    cat > "$MOCK_JSONL"
}

# ---------- happy path ----------

@test "drill restores explicit paths and verifies them against the live source" {
    export RESTORE_DRILL_PATHS="$REL_A:$REL_B"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Restore Drill"
    echo "$output" | grep -q "Archive: backup-drill-1"
    echo "$output" | grep -q "PASS: ${REL_A} .*matches live source"
    echo "$output" | grep -q "PASS: ${REL_B} .*matches live source"
    echo "$output" | grep -q "Matched source:   2"
    echo "$output" | grep -q "Failed:           0"
    echo "$output" | grep -q "Restore drill passed"
    echo "$output" | grep -q "NOTIFY: restore.success INFO"
}

@test "drill reports a file that differs from the live source as restored, not failed" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export MOCK_CORRUPT=1

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS: ${REL_A} .*differs from live source"
    echo "$output" | grep -q "Failed:           0"
    echo "$output" | grep -q "NOTIFY: restore.success INFO"
}

@test "drill verifies integrity when the source file no longer exists" {
    export RESTORE_DRILL_PATHS="tmp/absent-source-$$/gone.txt"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "integrity verified by borg; source no longer present"
    echo "$output" | grep -q "NOTIFY: restore.success INFO"
}

# ---------- failure paths ----------

@test "drill fails when a sampled file is not restored" {
    export RESTORE_DRILL_PATHS="$REL_A:$REL_B"
    export MOCK_EXTRACT_SKIP="$REL_B"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "FAIL: ${REL_B} - not present after extract"
    echo "$output" | grep -q "Failed:           1"
    echo "$output" | grep -q "RESTORE DRILL FAILED"
    echo "$output" | grep -q "NOTIFY: restore.failure CRITICAL"
}

@test "drill fails when borg extract fails" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export MOCK_EXTRACT_FAIL=2
    export MOCK_EXTRACT_MSG="Data integrity error"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "FAILED: borg extract exited 2"
    echo "$output" | grep -q "NOTIFY: restore.failure CRITICAL"
}

@test "drill fails when the repository has no archives" {
    export MOCK_ARCHIVE=""
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "no archives"
    echo "$output" | grep -q "NOTIFY: restore.failure CRITICAL"
}

@test "drill fails when listing archives errors" {
    export MOCK_LIST_FAIL=2
    export MOCK_LIST_MSG="Repository does not exist"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "could not list archives"
    echo "$output" | grep -q "NOTIFY: restore.failure CRITICAL"
}

# ---------- never disturb a running backup ----------

@test "drill skips without failing when the repository is locked" {
    export MOCK_LIST_FAIL=2
    export MOCK_LIST_MSG="Failed to create/acquire the lock"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIPPED: repository is locked"
    echo "$output" | grep -q "does not break locks"
    ! echo "$output" | grep -q "NOTIFY: restore.failure"
}

@test "drill skips when extract hits a lock" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export MOCK_EXTRACT_FAIL=2
    export MOCK_EXTRACT_MSG="Failed to create/acquire the lock"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIPPED: repository is locked"
    ! echo "$output" | grep -q "NOTIFY: restore.failure"
}

# ---------- sampling ----------

@test "drill samples regular files only, skipping dirs, empty and oversized files" {
    write_jsonl << EOF
{"type": "d", "path": "${REL_A%/a.txt}", "size": 0}
{"type": "-", "path": "${REL_A}", "size": 14}
{"type": "-", "path": "empty.txt", "size": 0}
{"type": "-", "path": "huge.bin", "size": 999999999}
{"type": "l", "path": "link.txt", "size": 5}
EOF
    export RESTORE_DRILL_SAMPLE_COUNT=5

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Eligible files in archive: 1"
    echo "$output" | grep -q -- "- ${REL_A}"
    ! echo "$output" | grep -q "empty.txt"
    ! echo "$output" | grep -q "huge.bin"
    ! echo "$output" | grep -q "link.txt"
}

@test "drill honours RESTORE_DRILL_MAX_FILE_BYTES" {
    write_jsonl << EOF
{"type": "-", "path": "${REL_A}", "size": 14}
{"type": "-", "path": "medium.bin", "size": 5000}
EOF
    export RESTORE_DRILL_MAX_FILE_BYTES=100
    export RESTORE_DRILL_SAMPLE_COUNT=5

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Eligible files in archive: 1"
    ! echo "$output" | grep -q "medium.bin"
}

@test "drill limits the sample to RESTORE_DRILL_SAMPLE_COUNT files" {
    write_jsonl << EOF
{"type": "-", "path": "${REL_A}", "size": 14}
{"type": "-", "path": "${REL_B}", "size": 13}
{"type": "-", "path": "tmp/c.txt", "size": 10}
{"type": "-", "path": "tmp/d.txt", "size": 10}
EOF
    export RESTORE_DRILL_SAMPLE_COUNT=2

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Eligible files in archive: 4"
    echo "$output" | grep -q "Files sampled:    2"
}

@test "drill fails when the archive has no eligible files" {
    write_jsonl << 'EOF'
{"type": "d", "path": "only-a-dir", "size": 0}
EOF

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "no eligible files found"
    echo "$output" | grep -q "RESTORE_DRILL_MAX_FILE_BYTES"
    echo "$output" | grep -q "NOTIFY: restore.failure CRITICAL"
}

# ---------- options ----------

@test "drill uses the archive named in RESTORE_DRILL_ARCHIVE" {
    export RESTORE_DRILL_ARCHIVE="backup-specific-archive"
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Archive requested: backup-specific-archive"
    echo "$output" | grep -q "Archive: backup-specific-archive"
}

@test "drill removes restored files by default" {
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    [ ! -d "$RESTORE_DRILL_TARGET" ]
}

@test "drill keeps restored files when RESTORE_DRILL_KEEP is true" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export RESTORE_DRILL_KEEP=true

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Restored files kept at"
    [ -f "${RESTORE_DRILL_TARGET}/${REL_A}" ]
}

@test "drill passes --lock-wait so it waits rather than failing instantly" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export RESTORE_DRILL_LOCK_WAIT=42

    # Log to a file, not stderr: the drill deliberately keeps stderr out of the
    # values it captures, so stderr would not appear in $output
    cat > "$TEST_DIR/bin/borg" << EOF
#!/bin/sh
echo "BORG_ARGS: \$*" >> "$TEST_DIR/borg-args.log"
cmd="\$1"; shift
if [ "\$cmd" = "extract" ]; then
    for a in "\$@"; do
        case "\$a" in --*|*::*|42) continue ;; esac
        mkdir -p "\$(dirname "\$a")"
        printf 'x\n' > "\$a"
    done
else
    printf '%s\n' "\$MOCK_ARCHIVE"
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    grep -q -- "--lock-wait 42" "$TEST_DIR/borg-args.log"
    # Both the archive lookup and the extract must wait rather than fail
    [ "$(grep -c -- '--lock-wait 42' "$TEST_DIR/borg-args.log")" -ge 2 ]
}
