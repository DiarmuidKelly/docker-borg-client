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
    # Keep stdout (the JSON) and stderr (warnings such as SSH host-key notices)
    # apart: mixing them makes the payload unparseable by jq.
    INFO_JSON=$(mktemp)
    INFO_ERR=$(borg info --json "$BORG_REPO" 2>&1 >"$INFO_JSON")
    INFO_EXIT=$?

    if [ $INFO_EXIT -eq 0 ]; then
        REPO_OK=true
        ok "Repository reachable and passphrase verified"

        ARCHIVE_COUNT=$(jq -r '.cache.stats.total_chunks // empty' < "$INFO_JSON" 2>/dev/null || true)
        REPO_SIZE=$(jq -r '.cache.stats.unique_csize // empty' < "$INFO_JSON" 2>/dev/null || true)
        if [ -n "$REPO_SIZE" ]; then
            echo "     Deduplicated size: $REPO_SIZE bytes, chunks: ${ARCHIVE_COUNT:-unknown}"
        fi

        LAST_ARCHIVE=$(borg list --last 1 --format '{archive} ({time}){NL}' "$BORG_REPO" 2>/dev/null | head -1)
        if [ -n "$LAST_ARCHIVE" ]; then
            ok "Most recent archive: $LAST_ARCHIVE"
        else
            warn "Repository has no archives yet - nothing could be restored today"
        fi
    elif printf '%s' "$INFO_ERR" | grep -q "passphrase supplied.*incorrect\|Wrong passphrase"; then
        bad "Passphrase is WRONG for this repository - restores would be impossible"
    elif printf '%s' "$INFO_ERR" | grep -qE "does not exist|Repository.*not.*found"; then
        warn "Repository does not exist yet (AUTO_INIT=${AUTO_INIT:-false} will create it)"
    else
        warn "Could not reach the repository right now:"
        printf '%s\n' "$INFO_ERR" | head -3 | sed 's/^/     /'
    fi
    rm -f "$INFO_JSON"
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
else
    warn "RESTORE_DRILL_ENABLED is not true - recoverability is never proven."
    echo "     An untested backup is not a backup. Run '/scripts/restore.sh drill'."
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
