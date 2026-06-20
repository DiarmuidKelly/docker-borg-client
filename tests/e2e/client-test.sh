#!/bin/sh
# Runs inside the borg-client container. Exercises the full backup → verify → restore cycle.
set -e

REPO="ssh://borguser@borg-server:22/~/backups"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }
step() { echo; echo "==> $*"; }

# ---------- wait for server ----------

step "Waiting for borg-server sshd"
i=0
while [ $i -lt 30 ]; do
    ssh -i /ssh/key \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=2 \
        borguser@borg-server true 2>/dev/null && break
    i=$((i + 1))
    sleep 1
done
[ $i -lt 30 ] || { echo "borg-server not reachable after 30s"; exit 1; }
echo "  SSH ready after ${i}s"

# ---------- init ----------

step "Initialising repository"
/scripts/init.sh

# ---------- backup ----------

step "Running backup (BACKUP_EXCLUDES=/source/excluded)"
/scripts/backup.sh

# ---------- verify archive exists ----------

step "Checking archive was created"
ARCHIVE_LIST=$(borg list "$REPO")
[ -n "$ARCHIVE_LIST" ] || fail "No archives found"
pass "Archive exists"

ARCHIVE_NAME=$(echo "$ARCHIVE_LIST" | awk 'NR==1{print $1}')
echo "  Archive: $ARCHIVE_NAME"

# ---------- verify file presence ----------

step "Checking expected files are in archive"
ARCHIVE_FILES=$(borg list "${REPO}::${ARCHIVE_NAME}")
echo "$ARCHIVE_FILES" | grep -q "important.txt" || fail "important.txt missing from archive"
echo "$ARCHIVE_FILES" | grep -q "nested.txt"    || fail "nested.txt missing from archive"
pass "Expected files present"

# ---------- verify excludes ----------

step "Checking excluded path is absent"
if echo "$ARCHIVE_FILES" | grep -q "excluded/ignored.txt"; then
    fail "excluded/ignored.txt found in archive — BACKUP_EXCLUDES not working"
else
    pass "Excluded path correctly absent"
fi

# ---------- verify ----------

step "Running borg check"
/scripts/verify.sh
pass "Repository integrity verified"

# ---------- restore ----------

step "Restoring and verifying file content"
mkdir -p /tmp/restore
cd /tmp/restore
borg extract "${REPO}::${ARCHIVE_NAME}" source/important.txt
grep -q "This file must be present" /tmp/restore/source/important.txt \
    || fail "Restored content does not match original"
pass "Restore verified"

# ---------- passphrase from file (issue #53) ----------
# Drive a real backup through the entrypoint with the passphrase sourced from a
# mounted file instead of BORG_PASSPHRASE, proving the resolution path works
# against the real server (not just the unit-test snippet).

step "Backup with BORG_PASSPHRASE_FILE (passphrase env unset)"
printf '%s' "$BORG_PASSPHRASE" > /tmp/pass.secret
COUNT_BEFORE=$(borg list "$REPO" | wc -l)
env -u BORG_PASSPHRASE BORG_PASSPHRASE_FILE=/tmp/pass.secret \
    /entrypoint.sh /scripts/backup.sh
COUNT_AFTER=$(borg list "$REPO" | wc -l)
[ "$COUNT_AFTER" -gt "$COUNT_BEFORE" ] \
    || fail "BORG_PASSPHRASE_FILE backup did not create a new archive"
pass "Passphrase-from-file backup succeeded"

# ---------- passphrase from command (issue #53) ----------
# BORG_PASSCOMMAND is borg-native: the passphrase never enters the environment.

step "Backup with BORG_PASSCOMMAND (passphrase env unset)"
COUNT_BEFORE=$(borg list "$REPO" | wc -l)
env -u BORG_PASSPHRASE BORG_PASSCOMMAND="cat /tmp/pass.secret" \
    /entrypoint.sh /scripts/backup.sh
COUNT_AFTER=$(borg list "$REPO" | wc -l)
[ "$COUNT_AFTER" -gt "$COUNT_BEFORE" ] \
    || fail "BORG_PASSCOMMAND backup did not create a new archive"
pass "Passphrase-from-command backup succeeded"

step "All E2E tests passed"
