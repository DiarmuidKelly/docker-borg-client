#!/bin/sh
# shellcheck shell=ash
# Startup preflight and recovery-readiness report.
#
# Checks the things you otherwise only discover you got wrong during a real
# recovery: an unreachable repository, a passphrase that does not actually
# unlock the key, a repository key that was never exported, no scheduled
# integrity check and no restore drill.
#
# Report-only by default: a backup container that refuses to start because the
# network is briefly down is worse than one that warns and retries on its next
# scheduled run. Set PREFLIGHT_STRICT=true to fail fast instead.

PREFLIGHT_STRICT="${PREFLIGHT_STRICT:-false}"
REPO_KEY_FILE="${REPO_KEY_FILE:-/borg/config/repo-key.txt}"
WARNINGS=0
FAILURES=0

warn() {
    echo "  ⚠  $1"
    WARNINGS=$((WARNINGS + 1))
}

bad() {
    echo "  ✗  $1"
    FAILURES=$((FAILURES + 1))
}

ok() {
    echo "  ✓  $1"
}

echo "========================================="
echo "Preflight / Recovery Readiness"
echo "========================================="

# ---------- 1. where the passphrase comes from ----------

if [ -n "${BORG_PASSCOMMAND:-}" ]; then
    ok "Passphrase source: BORG_PASSCOMMAND (never stored in the environment)"
elif [ -n "${BORG_PASSPHRASE_FILE:-}" ] && [ ! -f "$BORG_PASSPHRASE_FILE" ]; then
    # Reporting the file as the source when it cannot be read would hide the
    # very thing that went wrong - a secret mount that was forgotten or mistyped
    bad "BORG_PASSPHRASE_FILE is set to '$BORG_PASSPHRASE_FILE' but that file does not exist"
    if [ -n "${BORG_PASSPHRASE:-}" ]; then
        echo "     BORG_PASSPHRASE is also set, so backups would silently fall back"
        echo "     to the environment variable you were trying to avoid."
    fi
elif [ -n "${BORG_PASSPHRASE_FILE:-}" ]; then
    ok "Passphrase source: BORG_PASSPHRASE_FILE ($BORG_PASSPHRASE_FILE)"
elif [ -n "${BORG_PASSPHRASE:-}" ]; then
    warn "Passphrase source: BORG_PASSPHRASE env var - readable via 'docker inspect'."
    echo "     Consider BORG_PASSCOMMAND or BORG_PASSPHRASE_FILE on encrypted storage."
else
    bad "No passphrase configured - backups and restores will both fail"
fi

# ---------- 2. SSH key sanity ----------

# Pull the key path out of BORG_RSH (e.g. "ssh -i /ssh/key -o ...")
SSH_KEY=$(echo "${BORG_RSH:-}" | sed -n 's/.*-i[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p')

case "${BORG_REPO:-}" in
    ssh://*)
        if [ -z "$SSH_KEY" ]; then
            warn "Could not determine the SSH key path from BORG_RSH"
        elif [ ! -f "$SSH_KEY" ]; then
            bad "SSH key '$SSH_KEY' not found - mount it read-only at that path"
        else
            KEY_PERMS=$(stat -c '%a' "$SSH_KEY" 2>/dev/null || echo "unknown")
            case "$KEY_PERMS" in
                600|400) ok "SSH key present: $SSH_KEY (mode $KEY_PERMS)" ;;
                unknown) ok "SSH key present: $SSH_KEY" ;;
                *)
                    warn "SSH key '$SSH_KEY' has mode $KEY_PERMS - SSH may refuse it."
                    echo "     Expected 600 (or 400 for a read-only mount)."
                    ;;
            esac
        fi
        ;;
    *)
        ok "Local repository path - no SSH key required"
        ;;
esac

# ---------- 3. repository reachable AND passphrase actually unlocks it ----------
# This is the check that matters most: it proves the configured passphrase can
# decrypt the repository key, rather than assuming it.

REPO_OK=false
if [ -n "${BORG_REPO:-}" ]; then
    # `borg list` reads the manifest only. `borg info <repo>` was used here
    # originally, but its cache statistics force a chunks-cache sync, which on a
    # large repository (or after the cache volume is recreated) can block
    # startup for a very long time while holding the repository lock - before
    # cron has even started. Listing the newest archive proves reachability and
    # that the passphrase decrypts the key, which is the point of the check.
    #
    # Keep stdout and stderr apart: borg writes notices such as the SSH host-key
    # warning to stderr, which would otherwise corrupt the captured value.
    LIST_OUT=$(mktemp)
    LIST_ERR=$(borg list --last 1 --format '{archive} ({time}){NL}' "$BORG_REPO" 2>&1 >"$LIST_OUT")
    LIST_EXIT=$?

    if [ $LIST_EXIT -eq 0 ]; then
        REPO_OK=true
        ok "Repository reachable and passphrase verified"

        LAST_ARCHIVE=$(head -1 "$LIST_OUT")
        if [ -n "$LAST_ARCHIVE" ]; then
            ok "Most recent archive: $LAST_ARCHIVE"
        else
            warn "Repository has no archives yet - nothing could be restored today"
        fi
    elif printf '%s' "$LIST_ERR" | grep -q "passphrase supplied.*incorrect\|Wrong passphrase"; then
        bad "Passphrase is WRONG for this repository - restores would be impossible"
    elif printf '%s' "$LIST_ERR" | grep -qE "does not exist|Repository.*not.*found"; then
        if [ "${AUTO_INIT:-false}" = "true" ]; then
            warn "Repository does not exist yet - AUTO_INIT=true will create it"
        else
            bad "Repository does not exist and AUTO_INIT is not true, so nothing will create it"
        fi
    else
        warn "Could not reach the repository right now:"
        printf '%s\n' "$LIST_ERR" | head -3 | sed 's/^/     /'
    fi
    rm -f "$LIST_OUT"
else
    bad "BORG_REPO is not set"
fi

# ---------- 4. disaster-recovery insurance ----------

if [ -f "$REPO_KEY_FILE" ]; then
    ok "Repository key exported: $REPO_KEY_FILE"
    echo "     Store a copy OFF this machine, with the passphrase."
else
    if [ "$REPO_OK" = "true" ]; then
        warn "Repository key not exported - run '/scripts/restore.sh key-export'"
    fi
fi

# ---------- 5. scheduled safety nets ----------

if [ -n "${CRON_SCHEDULE:-}" ]; then
    ok "Scheduled backups: $CRON_SCHEDULE"
else
    warn "No CRON_SCHEDULE - backups only run on demand"
fi

if [ "${VERIFY_ENABLED:-false}" = "true" ]; then
    ok "Scheduled integrity checks enabled"
else
    warn "VERIFY_ENABLED is not true - repository corruption may go unnoticed"
fi

if [ "${RESTORE_DRILL_ENABLED:-false}" = "true" ]; then
    ok "Scheduled restore drills enabled"

    # A drill skips rather than breaking a repository lock, so a stale lock or a
    # schedule that never fires would otherwise go unnoticed for a whole quarter.
    # Report the age of the last success so that gap is visible on every start.
    DRILL_STATE_FILE="${RESTORE_DRILL_STATE_FILE:-/borg/config/last-restore-drill}"
    DRILL_MAX_AGE_DAYS="${RESTORE_DRILL_MAX_AGE_DAYS:-100}"

    if [ -f "$DRILL_STATE_FILE" ]; then
        DRILL_TS=$(awk '{print $1}' "$DRILL_STATE_FILE" 2>/dev/null)
        DRILL_ARCHIVE=$(awk '{print $2}' "$DRILL_STATE_FILE" 2>/dev/null)
        case "$DRILL_TS" in
            ''|*[!0-9]*)
                warn "Last restore drill timestamp in $DRILL_STATE_FILE is unreadable"
                ;;
            *)
                DRILL_AGE_DAYS=$(( ( $(date +%s) - DRILL_TS ) / 86400 ))
                DRILL_WHEN=$(date -d "@$DRILL_TS" '+%Y-%m-%d' 2>/dev/null \
                    || date -r "$DRILL_TS" '+%Y-%m-%d' 2>/dev/null \
                    || echo "unknown")
                if [ "$DRILL_AGE_DAYS" -gt "$DRILL_MAX_AGE_DAYS" ]; then
                    warn "Last successful restore drill: ${DRILL_WHEN} (${DRILL_AGE_DAYS} days ago)"
                    echo "     Drills may be skipping - a locked repository causes a skip."
                    echo "     Check the logs, or run '/scripts/restore.sh drill' now."
                else
                    ok "Last successful restore drill: ${DRILL_WHEN} (${DRILL_AGE_DAYS} days ago, ${DRILL_ARCHIVE})"
                fi
                ;;
        esac
    else
        warn "No restore drill has ever completed successfully"
        echo "     Run '/scripts/restore.sh drill' to prove recovery works."
    fi
else
    warn "RESTORE_DRILL_ENABLED is not true - recoverability is never proven."
    echo "     An untested backup is not a backup. Run '/scripts/restore.sh drill'."
fi

# ---------- 6. what each job did last time ----------
# Read back from the persistent history file. Container stdout is lost to log
# rotation and redeploys, so without this a failed verify leaves no trace.

HISTORY_FILE="${HISTORY_FILE:-/borg/config/history.log}"

if [ -f "$HISTORY_FILE" ]; then
    echo "-----------------------------------------"
    echo "Last run of each job (from $HISTORY_FILE)"

    for job in backup prune verify restore; do
        # Last recorded line for this job, whatever its outcome
        entry=$(grep " ${job}\." "$HISTORY_FILE" 2>/dev/null | tail -1)

        if [ -z "$entry" ]; then
            echo "  -  ${job}: no record yet"
            continue
        fi

        when=$(printf '%s' "$entry" | awk '{print $1}')
        event=$(printf '%s' "$entry" | awk '{print $2}')
        detail=$(printf '%s' "$entry" | sed 's/^[^|]*| *//')

        case "$event" in
            *.failure|*.error)
                warn "${job}: FAILED at ${when}"
                [ -n "$detail" ] && echo "     $detail"
                ;;
            *.skipped)
                # Not a failure, but nothing ran either - so it must not read as
                # a tick. A check that skips every week is a check that is not
                # happening.
                warn "${job}: SKIPPED at ${when} - did not run"
                [ -n "$detail" ] && echo "     $detail"
                echo "     A locked repository (a backup still running) causes a skip."
                echo "     If this repeats, move the schedule clear of the backup window."
                ;;
            *)
                ok "${job}: ${event} at ${when}"
                ;;
        esac
    done

    # Surface any failure still present in the retained history, even if the
    # job has since succeeded - a verify that found corruption once matters.
    FAILURES_IN_HISTORY=$(grep -cE " [a-z-]+\.(failure|error) " "$HISTORY_FILE" 2>/dev/null || true)
    case "$FAILURES_IN_HISTORY" in
        ''|*[!0-9]*) FAILURES_IN_HISTORY=0 ;;
    esac
    if [ "$FAILURES_IN_HISTORY" -gt 0 ]; then
        echo "     ${FAILURES_IN_HISTORY} failure event(s) in retained history:"
        echo "       grep -E '\.(failure|error) ' $HISTORY_FILE"
    fi
else
    echo "-----------------------------------------"
    echo "No job history yet ($HISTORY_FILE)"
fi

# ---------- summary ----------

echo "-----------------------------------------"
if [ "$FAILURES" -gt 0 ]; then
    echo "Preflight: $FAILURES problem(s), $WARNINGS warning(s)"
    echo "========================================="
    if [ "$PREFLIGHT_STRICT" = "true" ]; then
        echo "PREFLIGHT_STRICT=true - refusing to start"
        exit 1
    fi
    exit 0
fi

if [ "$WARNINGS" -gt 0 ]; then
    echo "Preflight: OK with $WARNINGS warning(s)"
else
    echo "Preflight: all checks passed"
fi
echo "========================================="
exit 0
