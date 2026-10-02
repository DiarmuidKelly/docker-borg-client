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

# Assert a backup produced a brand-new archive. Archive counts cannot be used
# for this: backup.sh runs prune on success, which may delete more archives
# than the run created, so the total can stay flat or shrink.
newest_archive() {
    borg list --last 1 --format '{archive}{NL}' "$REPO" | head -1
}

step "Backup with BORG_PASSPHRASE_FILE (passphrase env unset)"
printf '%s' "$BORG_PASSPHRASE" > /tmp/pass.secret
NEWEST_BEFORE=$(newest_archive)
env -u BORG_PASSPHRASE BORG_PASSPHRASE_FILE=/tmp/pass.secret \
    /entrypoint.sh /scripts/backup.sh
NEWEST_AFTER=$(newest_archive)
if [ -z "$NEWEST_AFTER" ] || [ "$NEWEST_AFTER" = "$NEWEST_BEFORE" ]; then
    fail "BORG_PASSPHRASE_FILE backup did not create a new archive"
fi
pass "Passphrase-from-file backup succeeded (new archive: $NEWEST_AFTER)"

# ---------- passphrase from command (issue #53) ----------
# BORG_PASSCOMMAND is borg-native: the passphrase never enters the environment.

step "Backup with BORG_PASSCOMMAND (passphrase env unset)"
NEWEST_BEFORE=$(newest_archive)
env -u BORG_PASSPHRASE BORG_PASSCOMMAND="cat /tmp/pass.secret" \
    /entrypoint.sh /scripts/backup.sh
NEWEST_AFTER=$(newest_archive)
if [ -z "$NEWEST_AFTER" ] || [ "$NEWEST_AFTER" = "$NEWEST_BEFORE" ]; then
    fail "BORG_PASSCOMMAND backup did not create a new archive"
fi
pass "Passphrase-from-command backup succeeded (new archive: $NEWEST_AFTER)"

# ---------- recovery flow ----------
# The restore path is the one that matters most and the one least often
# exercised, so drive the real scripts against the real server.

step "Preflight / recovery-readiness report"
/scripts/preflight.sh | tee /tmp/preflight.out
grep -q "Repository reachable and passphrase verified" /tmp/preflight.out \
    || fail "preflight did not verify repository access"
grep -q "Most recent archive" /tmp/preflight.out \
    || fail "preflight did not report the most recent archive"
pass "Preflight verified repo access and passphrase"

step "restore.sh latest resolves the newest archive"
LATEST=$(/scripts/restore.sh latest | grep '^backup-')
[ -n "$LATEST" ] || fail "restore.sh latest returned nothing"
echo "  Latest: $LATEST"
borg list "$REPO" | grep -q "$LATEST" || fail "resolved archive is not in the repository"
pass "latest resolved to a real archive"

step "restore.sh files lists archive contents"
/scripts/restore.sh files latest important.txt | grep -q "source/important.txt" \
    || fail "files action did not list important.txt"
pass "files action lists and filters archive contents"

step "restore.sh dry-run verifies an archive without writing"
rm -rf /tmp/dryrun-check
mkdir -p /tmp/dryrun-check
cd /tmp/dryrun-check
/scripts/restore.sh dry-run latest > /tmp/dryrun.out 2>&1 \
    || { cat /tmp/dryrun.out; fail "dry-run failed"; }
grep -q "Dry-run completed" /tmp/dryrun.out || fail "dry-run did not report completion"
[ -z "$(ls -A /tmp/dryrun-check)" ] || fail "dry-run wrote files - it must not"
cd /
pass "dry-run verified the archive and wrote nothing"

step "restore.sh extract restores a single named path"
rm -rf /tmp/selective
/scripts/restore.sh extract latest /tmp/selective source/subdir/nested.txt
[ -f /tmp/selective/source/subdir/nested.txt ] || fail "selective extract did not restore the file"
[ ! -f /tmp/selective/source/important.txt ] \
    || fail "selective extract restored more than the requested path"
pass "selective extract restored exactly the requested path"

step "restore.sh refuses to extract over the live source data"
if /scripts/restore.sh extract latest / 2>/tmp/guard.out; then
    fail "extract to / was permitted - the fail-safe is not working"
fi
grep -q "refusing to extract at '/'" /tmp/guard.out || fail "unexpected guard message"
if /scripts/restore.sh extract latest /source/restore-here 2>/tmp/guard2.out; then
    fail "extract into a backup source path was permitted"
fi
grep -q "inside backup source" /tmp/guard2.out || fail "unexpected guard message for source path"
pass "destination fail-safes refused both unsafe targets"

step "Restore drill proves recoverability end to end"
RESTORE_DRILL_SAMPLE_COUNT=2 /scripts/restore-drill.sh | tee /tmp/drill.out
grep -q "Restore drill passed" /tmp/drill.out || fail "restore drill did not pass"
grep -q "matches live source" /tmp/drill.out \
    || fail "drill did not byte-compare any restored file against the source"
pass "Restore drill passed with source comparison"

step "Restore drill detects an unrecoverable file"
if RESTORE_DRILL_PATHS="source/definitely-not-in-archive.txt" \
    /scripts/restore-drill.sh > /tmp/drill-fail.out 2>&1; then
    cat /tmp/drill-fail.out
    fail "drill reported success for a file that is not in the archive"
fi
pass "Drill fails loudly when a file cannot be restored"

step "restore.sh key-export writes the repository key"
/scripts/restore.sh key-export /tmp/exported-key.txt
grep -q "BORG_KEY" /tmp/exported-key.txt || fail "exported key does not look like a borg key"
pass "Repository key exported for disaster recovery"

step "borg mount reports a clear error without /dev/fuse"
# The E2E container has no /dev/fuse, so this asserts the preflight message
# rather than a working mount (mounting needs --device/--cap-add/apparmor).
if /scripts/restore.sh mount latest /tmp/mnt 2>/tmp/mount.out; then
    fail "mount unexpectedly succeeded without /dev/fuse"
fi
grep -q "/dev/fuse is not present" /tmp/mount.out \
    || { cat /tmp/mount.out; fail "mount did not report the expected FUSE guidance"; }
pass "Mount preflight gave actionable guidance"

step "FUSE bindings are present in the image"
python3 -c 'import pyfuse3' 2>/dev/null \
    || fail "pyfuse3 missing - borg mount would be unavailable even with /dev/fuse"
pass "borgbackup-fuse bindings installed"

step "All E2E tests passed"
