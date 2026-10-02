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

    # borg reports a healthy, reachable repository by default
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
if [ -n "$MOCK_INFO_FAIL" ]; then
    if [ "$1" = "info" ]; then
        echo "$MOCK_INFO_MSG" >&2
        exit "$MOCK_INFO_FAIL"
    fi
fi
case "$1" in
  info)
    echo '{"cache":{"stats":{"total_chunks":1234,"unique_csize":5678}}}'
    ;;
  list)
    printf '%s\n' "${MOCK_LAST_ARCHIVE-backup-2026-10-02_01-00-00 (Fri, 2026-10-02 01:00:04)}"
    ;;
  --version) echo "borg 1.4.4" ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/bin/borg"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset BORG_REPO BORG_PASSPHRASE BORG_PASSPHRASE_FILE BORG_PASSCOMMAND
    unset BORG_RSH REPO_KEY_FILE PREFLIGHT_STRICT AUTO_INIT
    unset MOCK_INFO_FAIL MOCK_INFO_MSG MOCK_LAST_ARCHIVE
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
    export BORG_PASSPHRASE_FILE="/run/secrets/passphrase"

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*BORG_PASSPHRASE_FILE"
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
# the JSON goes to stdout. Mixing the two made the payload unparseable and
# aborted the whole report part-way through, hiding every later check.
@test "completes the report when borg emits warnings on stderr" {
    cat > "$TEST_DIR/bin/borg" << 'EOF'
#!/bin/sh
case "$1" in
  info)
    echo "Remote: Warning: Permanently added 'host' to the list of known hosts." >&2
    echo '{"cache":{"stats":{"total_chunks":10,"unique_csize":20}}}'
    ;;
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
    export MOCK_INFO_FAIL=2
    export MOCK_INFO_MSG="Wrong passphrase supplied for repository"

    run sh "$PREFLIGHT_SCRIPT"
    echo "$output" | grep -q "✗.*Passphrase is WRONG"
    echo "$output" | grep -q "restores would be impossible"
}

@test "treats a not-yet-created repository as a warning when AUTO_INIT is set" {
    export MOCK_INFO_FAIL=2
    export MOCK_INFO_MSG="Repository /repo does not exist."
    export AUTO_INIT=true

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "⚠.*does not exist yet"
    echo "$output" | grep -q "AUTO_INIT=true"
}

@test "warns when the repository is unreachable for another reason" {
    export MOCK_INFO_FAIL=2
    export MOCK_INFO_MSG="Connection refused"

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

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "✓.*Scheduled backups: 0 2 \* \* 0"
    echo "$output" | grep -q "✓.*Scheduled integrity checks enabled"
    echo "$output" | grep -q "✓.*Scheduled restore drills enabled"
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

    run sh "$PREFLIGHT_SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Preflight: all checks passed"
}
