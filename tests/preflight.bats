#!/usr/bin/env bats

# Test preflight.sh - the startup recovery-readiness report. Its job is to
# surface the misconfigurations you would otherwise only discover during a real
# recovery (wrong passphrase, unreachable repo, key never exported).

setup() {
    PREFLIGHT_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/preflight.sh"

    TEST_DIR="/tmp/test-preflight-$$"
    mkdir -p "$TEST_DIR/bin"

    export PATH="$TEST_DIR/bin:$PATH"
    export BORG_REPO="ssh://user@host:22/~/backups"
    export BORG_PASSPHRASE="test-passphrase"
    export BORG_RSH="ssh -i $TEST_DIR/key -o StrictHostKeyChecking=accept-new"
    export REPO_KEY_FILE="$TEST_DIR/repo-key.txt"

    # A well-formed SSH key by default
    printf 'FAKE KEY\n' > "$TEST_DIR/key"
    chmod 600 "$TEST_DIR/key"

    # borg reports a healthy, reachable repository by default.
    # The repository probe is `borg list --last 1` (not `borg info`, whose cache
    # statistics force a chunks-cache sync).
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
case "$1" in
  list)
    if [ -n "$MOCK_REPO_FAIL" ]; then
        echo "$MOCK_REPO_MSG" >&2
        exit "$MOCK_REPO_FAIL"
    fi
    printf '%s\n' "${MOCK_LAST_ARCHIVE-backup-2026-10-02_01-00-00 (Fri, 2026-10-02 01:00:04)}"
    ;;
  info)
    echo "MOCK_BORG_INFO_SHOULD_NOT_BE_CALLED" >&2
    exit 1
    ;;
  --version) echo "borg 1.4.4" ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    # Drill state and job history live under /borg/config in the image; keep
    # tests out of it
    export RESTORE_DRILL_STATE_FILE="$TEST_DIR/last-drill"
    export HISTORY_FILE="$TEST_DIR/history.log"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset BORG_REPO BORG_PASSPHRASE BORG_PASSPHRASE_FILE BORG_PASSCOMMAND
    unset BORG_RSH REPO_KEY_FILE PREFLIGHT_STRICT AUTO_INIT
    unset MOCK_REPO_FAIL MOCK_REPO_MSG MOCK_LAST_ARCHIVE
    unset RESTORE_DRILL_STATE_FILE RESTORE_DRILL_MAX_AGE_DAYS HISTORY_FILE
    unset CRON_SCHEDULE VERIFY_ENABLED RESTORE_DRILL_ENABLED
}

# ---------- passphrase source ----------

@test "reports BORG_PASSCOMMAND as the strongest passphrase source" {
    export BORG_PASSCOMMAND="cat /run/secrets/passphrase"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*BORG_PASSCOMMAND"
    echo "$output" | grep -q "never stored in the environment"
}

@test "reports BORG_PASSPHRASE_FILE as the passphrase source" {
    unset BORG_PASSPHRASE
    export BORG_PASSPHRASE_FILE="$TEST_DIR/passphrase"
    printf 'secret\n' > "$BORG_PASSPHRASE_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*BORG_PASSPHRASE_FILE"
}

# A secret mount that was forgotten or mistyped must not be reported as a
# working file-based passphrase - that hides the actual fault.
@test "flags BORG_PASSPHRASE_FILE pointing at a missing file" {
    unset BORG_PASSPHRASE
    export BORG_PASSPHRASE_FILE="$TEST_DIR/does-not-exist"

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*BORG_PASSPHRASE_FILE is set.*does not exist"
    ! echo "$output" | grep -q "✓.*BORG_PASSPHRASE_FILE"
}

@test "warns that a missing passphrase file falls back to the env var" {
    export BORG_PASSPHRASE="leftover-from-old-config"
    export BORG_PASSPHRASE_FILE="$TEST_DIR/does-not-exist"

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*does not exist"
    echo "$output" | grep -q "silently fall back"
}

@test "warns when the passphrase comes from a plain environment variable" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*BORG_PASSPHRASE env var"
    echo "$output" | grep -q "docker inspect"
}

@test "flags a missing passphrase as a problem" {
    unset BORG_PASSPHRASE

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*No passphrase configured"
}

# ---------- SSH key ----------

@test "accepts an SSH key with mode 600" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*SSH key present"
}

@test "flags a missing SSH key" {
    rm -f "$TEST_DIR/key"

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*SSH key.*not found"
}

@test "warns about over-permissive SSH key modes" {
    chmod 644 "$TEST_DIR/key"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*mode 644"
    echo "$output" | grep -q "Expected 600"
}

@test "skips the SSH key check for a local repository path" {
    export BORG_REPO="/repo"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "no SSH key required"
}

# ---------- repository reachability and passphrase validity ----------

@test "confirms the repository is reachable and the passphrase works" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*Repository reachable and passphrase verified"
    echo "$output" | grep -q "Most recent archive"
}

# Regression: borg writes warnings (e.g. SSH host-key notices) to stderr while
# the payload goes to stdout. Mixing the two corrupted the captured value and
# aborted the whole report part-way through, hiding every later check.
@test "completes the report when borg emits warnings on stderr" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
case "$1" in
  list)
    echo "Remote: Warning: Permanently added 'host' to the list of known hosts." >&2
    echo "backup-2026-10-02_01-00-00 (Fri, 2026-10-02 01:00:04)"
    ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Repository reachable and passphrase verified"
    echo "$output" | grep -q "Most recent archive"
    # The checks after the repository section must still run
    echo "$output" | grep -q "Repository key not exported"
    echo "$output" | grep -q "RESTORE_DRILL_ENABLED is not true"
    echo "$output" | grep -q "Preflight: OK with"
}

@test "flags a wrong passphrase as a problem" {
    export MOCK_REPO_FAIL=2
    export MOCK_REPO_MSG="Wrong passphrase supplied for repository"

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*Passphrase is WRONG"
    echo "$output" | grep -q "restores would be impossible"
}

@test "treats a not-yet-created repository as a warning when AUTO_INIT is set" {
    export MOCK_REPO_FAIL=2
    export MOCK_REPO_MSG="Repository /repo does not exist."
    export AUTO_INIT=true

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*does not exist yet"
    echo "$output" | grep -q "AUTO_INIT=true"
}

@test "warns when the repository is unreachable for another reason" {
    export MOCK_REPO_FAIL=2
    export MOCK_REPO_MSG="Connection refused"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*Could not reach the repository"
    echo "$output" | grep -q "Connection refused"
}

@test "warns when the repository has no archives yet" {
    export MOCK_LAST_ARCHIVE=""

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*no archives yet"
    echo "$output" | grep -q "nothing could be restored today"
}

# ---------- disaster-recovery insurance ----------

@test "confirms an exported repository key" {
    printf 'BORG_KEY abc123\n' > "$REPO_KEY_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*Repository key exported"
    echo "$output" | grep -q "OFF this machine"
}

@test "warns when the repository key was never exported" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*Repository key not exported"
    echo "$output" | grep -q "key-export"
}

# ---------- scheduled safety nets ----------

@test "warns when no scheduled integrity check or restore drill is configured" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*VERIFY_ENABLED is not true"
    echo "$output" | grep -q "⚠.*RESTORE_DRILL_ENABLED is not true"
    echo "$output" | grep -q "An untested backup is not a backup"
}

@test "confirms configured safety nets" {
    export CRON_SCHEDULE="0 2 * * 0"
    export VERIFY_ENABLED=true
    export RESTORE_DRILL_ENABLED=true
    printf '%s drill-archive\n' "$(date +%s)" > "$RESTORE_DRILL_STATE_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*Scheduled backups: 0 2 \* \* 0"
    echo "$output" | grep -q "✓.*Scheduled integrity checks enabled"
    echo "$output" | grep -q "✓.*Scheduled restore drills enabled"
}

# ---------- restore drill recency ----------
# A drill skips rather than breaking a lock, so a drill that never runs must not
# be invisible behind a quarterly schedule.

@test "reports the age of the last successful restore drill" {
    export RESTORE_DRILL_ENABLED=true
    printf '%s backup-2026-10-01_01-00-00\n' "$(date +%s)" > "$RESTORE_DRILL_STATE_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*Last successful restore drill:.*0 days ago"
    echo "$output" | grep -q "backup-2026-10-01_01-00-00"
}

@test "warns when the last restore drill is older than the allowed age" {
    export RESTORE_DRILL_ENABLED=true
    export RESTORE_DRILL_MAX_AGE_DAYS=30
    OLD=$(( $(date +%s) - 60 * 86400 ))
    printf '%s old-archive\n' "$OLD" > "$RESTORE_DRILL_STATE_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*Last successful restore drill:.*60 days ago"
    echo "$output" | grep -q "Drills may be skipping"
}

@test "warns when no restore drill has ever succeeded" {
    export RESTORE_DRILL_ENABLED=true

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*No restore drill has ever completed successfully"
}

@test "warns when the drill timestamp is unreadable" {
    export RESTORE_DRILL_ENABLED=true
    printf 'not-a-timestamp junk\n' > "$RESTORE_DRILL_STATE_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*timestamp.*unreadable"
}

@test "does not probe drill recency when drills are disabled" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "Last successful restore drill"
}

# ---------- repository probe must not force a cache sync ----------

@test "uses borg list rather than borg info for the repository probe" {
    # `borg info <repo>` reports cache statistics, which forces a chunks-cache
    # sync that can block startup for a long time on a large repository.
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "MOCK_BORG_INFO_SHOULD_NOT_BE_CALLED"
}

@test "escalates a missing repository to a problem when AUTO_INIT is off" {
    export MOCK_REPO_FAIL=2
    export MOCK_REPO_MSG="Repository /repo does not exist."
    export AUTO_INIT=false

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*Repository does not exist and AUTO_INIT is not true"
    # The old message claimed "AUTO_INIT=false will create it", which is untrue
    ! echo "$output" | grep -q "AUTO_INIT=false will create it"
}

@test "warns when backups are on-demand only" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*No CRON_SCHEDULE"
}

# ---------- exit behaviour ----------

@test "is report-only by default so a transient fault cannot crash-loop the container" {
    unset BORG_PASSPHRASE
    rm -f "$TEST_DIR/key"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "problem(s)"
}

@test "refuses to start on a problem when PREFLIGHT_STRICT is true" {
    unset BORG_PASSPHRASE
    export PREFLIGHT_STRICT=true

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "PREFLIGHT_STRICT=true - refusing to start"
}

@test "passes cleanly with a fully configured setup" {
    export BORG_PASSCOMMAND="cat /run/secrets/passphrase"
    export CRON_SCHEDULE="0 2 * * 0"
    export VERIFY_ENABLED=true
    export RESTORE_DRILL_ENABLED=true
    printf 'BORG_KEY abc123\n' > "$REPO_KEY_FILE"
    printf '%s recent-archive\n' "$(date +%s)" > "$RESTORE_DRILL_STATE_FILE"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Preflight: all checks passed"
}

# ---------- job history ----------
# Container stdout is lost to log rotation and redeploys, so the persistent
# history file is the only durable record of what each job did. Preflight reads
# it back on every start.

@test "reports the last run of each job from the history file" {
    cat > "$HISTORY_FILE" <<'HIST'
2026-10-01T01:03:11+0000 backup.success INFO Borg Backup Successful | Archive: backup-1, Duration: 206s
2026-10-01T01:03:12+0000 prune.success INFO Borg Prune Successful | Retention: 7d/4w/6m
2026-10-02T01:03:40+0000 backup.success INFO Borg Backup Successful | Archive: backup-2, Duration: 211s
HIST

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Last run of each job"
    # The most recent backup entry wins
    echo "$output" | grep -q "✓.*backup: backup.success at 2026-10-02T01:03:40"
    echo "$output" | grep -q "✓.*prune: prune.success at 2026-10-01T01:03:12"
    echo "$output" | grep -q "verify: no record yet"
}

@test "flags a failed job from the history file" {
    cat > "$HISTORY_FILE" <<'HIST'
2026-09-29T03:14:02+0000 verify.failure CRITICAL Borg Verification Failed | Level: archives, Exit code: 2
HIST

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*verify: FAILED at 2026-09-29T03:14:02"
    echo "$output" | grep -q "Level: archives, Exit code: 2"
}

# A verify that detected corruption matters even if a later run passed
@test "surfaces failures still present in retained history" {
    cat > "$HISTORY_FILE" <<'HIST'
2026-09-29T03:14:02+0000 verify.failure CRITICAL Borg Verification Failed | Exit code: 2
2026-10-01T03:14:02+0000 verify.success INFO Borg Verification Successful | Level: repository
HIST

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    # Latest state is a pass...
    echo "$output" | grep -q "✓.*verify: verify.success"
    # ...but the earlier failure is still called out
    echo "$output" | grep -q "1 failure event(s) in retained history"
}

@test "reports when there is no history yet" {
    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No job history yet"
}

@test "treats a restore drill failure as a job failure" {
    cat > "$HISTORY_FILE" <<'HIST'
2026-10-02T08:12:00+0000 restore.failure CRITICAL Borg Restore Drill Failed | 1 of 3 sampled files could not be restored
HIST

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*restore: FAILED at 2026-10-02T08:12:00"
}
