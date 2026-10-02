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

    # The drill sources lib-paths.sh relative to its own location
    cp "${BATS_TEST_DIRNAME}/../scripts/lib-paths.sh" "$TEST_DIR/lib-paths.sh"

    # Drill state is written to /borg/config by default; keep tests out of it
    export RESTORE_DRILL_STATE_FILE="$TEST_DIR/last-drill"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset BORG_REPO MOCK_ARCHIVE MOCK_JSONL MOCK_LIST_FAIL MOCK_LIST_MSG
    unset MOCK_EXTRACT_FAIL MOCK_EXTRACT_MSG MOCK_EXTRACT_SKIP MOCK_CORRUPT
    unset RESTORE_DRILL_PATHS RESTORE_DRILL_TARGET RESTORE_DRILL_SAMPLE_COUNT
    unset RESTORE_DRILL_ARCHIVE RESTORE_DRILL_KEEP RESTORE_DRILL_MAX_FILE_BYTES
    unset RESTORE_DRILL_STATE_FILE RESTORE_DRILL_LOCK_WAIT
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
    # Each run works in its own subdirectory under the configured target
    [ -n "$(find "$RESTORE_DRILL_TARGET" -name 'a.txt' -type f 2>/dev/null)" ]
}

# ---------- the drill deletes its target, so the target needs a guard ----------
# Regression: RESTORE_DRILL_TARGET was rm -rf'd unvalidated, so pointing it at a
# mounted restore directory (as the README suggests) wiped it every drill, and
# pointing it inside BACKUP_PATHS deleted live source data on a cron schedule.

@test "drill refuses to run with its target set to /" {
    export RESTORE_DRILL_TARGET="/"
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "refusing to run a restore drill at '/'"
}

@test "drill refuses a target inside a backup source" {
    export BACKUP_PATHS="/data/photos"
    export RESTORE_DRILL_TARGET="/data/photos/drill"
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "inside backup source '/data/photos'"
    echo "$output" | grep -q "scratch path outside your backup"
    unset BACKUP_PATHS
}

@test "drill never deletes the configured target itself, only its own subdirectory" {
    export RESTORE_DRILL_PATHS="$REL_A"
    mkdir -p "$RESTORE_DRILL_TARGET"
    printf 'do not delete me\n' > "$RESTORE_DRILL_TARGET/pre-existing.txt"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    # The operator's file and directory survive
    [ -f "$RESTORE_DRILL_TARGET/pre-existing.txt" ]
    grep -q "do not delete me" "$RESTORE_DRILL_TARGET/pre-existing.txt"
    # But the drill's own run directory is gone
    [ -z "$(find "$RESTORE_DRILL_TARGET" -maxdepth 1 -name 'run-*' 2>/dev/null)" ]
}

# ---------- borg warnings are not failures ----------
# With BORG_EXIT_CODES=modern, 1 and 100-127 are warnings. Unsupported xattrs or
# ACLs on the restore target produce them routinely; treating them as failures
# fired CRITICAL alerts for drills whose files all came back intact.

@test "drill treats a borg warning exit as a warning and still verifies" {
    export RESTORE_DRILL_PATHS="$REL_A"

    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
cmd="$1"; shift
if [ "$cmd" = "extract" ]; then
    skip_next=0
    for a in "$@"; do
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        case "$a" in
            --lock-wait) skip_next=1; continue ;;
            --*) continue ;;
            *::*) continue ;;
        esac
        mkdir -p "$(dirname "$a")"
        cp "/$a" "$a" 2>/dev/null || printf 'x\n' > "$a"
    done
    echo "setting xattr failed, unsupported on this filesystem" >&2
    exit 105
fi
printf '%s\n' "$MOCK_ARCHIVE"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "borg extract reported warnings (exit 105)"
    echo "$output" | grep -q "PASS: ${REL_A}"
    echo "$output" | grep -q "borg warnings:    yes (extract exit 105)"
    echo "$output" | grep -q "NOTIFY: restore.success INFO"
    ! echo "$output" | grep -q "NOTIFY: restore.failure"
}

@test "drill still fails on a warning exit when a file is genuinely missing" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export MOCK_EXTRACT_FAIL=101
    export MOCK_EXTRACT_MSG="Include pattern 'x' never matched."

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "reported warnings (exit 101)"
    echo "$output" | grep -q "FAIL: ${REL_A} - not present after extract"
    echo "$output" | grep -q "NOTIFY: restore.failure CRITICAL"
}

@test "drill fails hard on a borg error exit" {
    export RESTORE_DRILL_PATHS="$REL_A"
    export MOCK_EXTRACT_FAIL=2
    export MOCK_EXTRACT_MSG="Data integrity error"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "FAILED: borg extract exited 2"
}

# ---------- configuration validation ----------

@test "drill rejects a non-numeric sample count as a configuration error" {
    export RESTORE_DRILL_SAMPLE_COUNT="three"
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "RESTORE_DRILL_SAMPLE_COUNT must be a non-negative integer"
    # Must not masquerade as a failed drill
    ! echo "$output" | grep -q "NOTIFY: restore.failure"
}

@test "drill rejects a non-numeric max file size" {
    export RESTORE_DRILL_MAX_FILE_BYTES="100MB"
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "RESTORE_DRILL_MAX_FILE_BYTES must be a non-negative integer"
}

# ---------- recording success for the preflight recency report ----------

@test "drill records a timestamp on success" {
    export RESTORE_DRILL_PATHS="$REL_A"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    [ -f "$RESTORE_DRILL_STATE_FILE" ]
    # <epoch> <archive>
    grep -qE "^[0-9]+ backup-drill-1$" "$RESTORE_DRILL_STATE_FILE"
}

@test "drill does not record a timestamp when it fails" {
    export RESTORE_DRILL_PATHS="$REL_A:$REL_B"
    export MOCK_EXTRACT_SKIP="$REL_B"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 1 ]
    [ ! -f "$RESTORE_DRILL_STATE_FILE" ]
}

@test "drill does not record a timestamp when it skips on a lock" {
    export MOCK_LIST_FAIL=2
    export MOCK_LIST_MSG="Failed to create/acquire the lock"

    run sh "$TEST_DIR/drill.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$RESTORE_DRILL_STATE_FILE" ]
}

@test "drill defaults to a short lock wait" {
    export RESTORE_DRILL_PATHS="$REL_A"

    cat > "$TEST_DIR/bin/borg" << EOF
#!/bin/sh
echo "BORG_ARGS: \$*" >> "$TEST_DIR/borg-args.log"
cmd="\$1"; shift
if [ "\$cmd" = "extract" ]; then
    for a in "\$@"; do
        case "\$a" in --*|*::*|[0-9]*) continue ;; esac
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
    # Issue #42: a long blocking lock wait outlived the container. 60s, not 300s.
    grep -q -- "--lock-wait 60" "$TEST_DIR/borg-args.log"
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
