# Issue #10: Backup Window Enforcement Implementation Plan

**Issue**: Backup window not enforced during long-running backups
**Date**: 2026-01-19
**Status**: Planning (Revised - Checkpoint-based approach)
**Revision**: 2 - Simplified using Borg's native checkpoint feature

## Problem Summary

The backup window (`BACKUP_WINDOW_START` / `BACKUP_WINDOW_END`) is only checked once at the start of a backup. Long-running backups that start inside the window will continue to completion even after the window ends, potentially consuming bandwidth during business hours.

## Current Behaviour

- Backup starts at 01:00 (inside window)
- Window check happens at `scripts/backup.sh:52` (before `borg create`)
- Backup still running at 07:46 (outside window)
- No rate limiting or stopping applied after window ends

## Borg Checkpoint Feature (Key Discovery)

**Borg automatically supports interrupted backup resume via checkpoints:**

- Creates `.checkpoint` archives every 30 minutes by default (configurable with `--checkpoint-interval`)
- If backup is interrupted (Ctrl-C, kill, container restart), **simply running `borg create` again auto-resumes from last checkpoint**
- Only re-transfers data since last checkpoint (max 30 min of work lost)
- Checkpoints are automatically cleaned up by `borg prune`
- Reference: [Borg issue #660](https://github.com/borgbackup/borg/issues/660)

**⚠️ Borg 1.1+ Required:**
- Borg 1.0.x: Checkpoints only at file boundaries (significant drift with large files)
- Borg 1.1+: Checkpoints within files using `.borg_part_<N>` (minimal drift)
- **This implementation requires Borg 1.1 or later**

**Checkpoint Overhead:**

- 5-minute intervals cause excessive cache writes (>1GB bursts every 5 minutes)
- Default changed from 5→30 minutes in Borg 1.1 due to performance complaints
- **Recommendation: Use 30-minute default** (good balance between progress preservation and overhead)
- Reference: [Borg issue #896](https://github.com/borgbackup/borg/issues/896), [#2841](https://github.com/borgbackup/borg/issues/2841)

## Revised Approach: Kill & Auto-Resume (KISS)

**Instead of SIGSTOP/SIGCONT pause/resume complexity, leverage Borg's checkpoint feature:**

1. **When exiting window with rate=0**: Kill the `borg create` process (SIGTERM)
2. **On next window**: Run `borg create` normally - Borg auto-resumes from last checkpoint
3. **Container restart**: Break lock, run again - Borg resumes from checkpoint
4. **No state files, no PID tracking needed**

## Desired Behaviour

When a backup exits the configured window during execution:
- If `BACKUP_RATE_LIMIT_OUT_WINDOW=0`: **Terminate backup** (SIGTERM)
- If `BACKUP_RATE_LIMIT_OUT_WINDOW=<positive>`: Cannot change mid-backup (Borg limitation)
- If `BACKUP_RATE_LIMIT_OUT_WINDOW=-1`: Continue unlimited (no action needed)

When next window arrives:
- Run `borg create` normally
- Borg auto-detects checkpoint and resumes from where it left off
- Window monitor spawns to watch for next window expiry

## Rate Limit Semantics

- **`-1`**: Unlimited (no rate limit)
- **`0`**: Terminate backup when outside window, auto-resume from checkpoint in next window
- **Positive values**: Fixed rate limit in Mbps (cannot change mid-backup without restart)

**Important**: Borg doesn't support dynamic rate limit changes on running backups.

## Container Restart Handling

**Problem:**
- Power loss, TrueNAS updates, ENV changes all cause container restarts
- Locks remain from interrupted backups

**Solution:**
On startup (`entrypoint.sh`), check for stale locks and break them:

```bash
# Auto-initialize repository if enabled and not exists
if [ "$AUTO_INIT" = "true" ]; then
    echo "Checking if repository exists..."

    # Try to list repository and capture output
    BORG_CHECK_OUTPUT=$(borg list "$BORG_REPO" 2>&1)
    BORG_CHECK_EXIT=$?

    if [ $BORG_CHECK_EXIT -eq 0 ]; then
        # Repository exists and is accessible
        echo "Repository already exists"

    elif echo "$BORG_CHECK_OUTPUT" | grep -q "Lock.*by.*PID"; then
        # Repository is locked - likely from interrupted backup
        echo "⚠️  Repository locked from previous session, breaking lock..."
        borg break-lock "$BORG_REPO" 2>/dev/null || true
        echo "Lock broken - next backup will resume from checkpoint"

    else
        # Repository doesn't exist - initialize it
        /scripts/init.sh
    fi
fi
```

**Why auto-break locks on restart:**
- Container restart means previous backup process is gone
- Manual intervention impractical for automated systems
- Borg's checkpoint feature ensures resume from last checkpoint
- Already-uploaded chunks won't re-upload (deduplication)
- Incomplete checkpoint archives cleaned by prune policy

**Trade-offs:**
- Max 30 minutes of work lost (last checkpoint interval) - mitigated by grace period
- Checkpoint archives remain until next successful backup + prune
- Grace period allows up to 18 min (60% of checkpoint interval) of out-of-window bandwidth

## Grace Period Optimization

**Problem:** Without grace period, backups can waste significant work:
- Checkpoint at 06:30, window ends at 07:00
- Backup continues for 29 minutes until killed at 07:00
- **29 minutes of work discarded** (no checkpoint created)
- Next day: re-does those 29 minutes

**Solution:** Allow backup to continue past window end to complete checkpoint:
- Window ends at 07:00 → enter grace period (18 min)
- Grace period allows checkpoint to complete
- If checkpoint completes at 07:10 → terminate immediately
- If no checkpoint by 07:18 → terminate anyway (grace expired)

**Result:**
- Best case: Zero wasted work (checkpoint completed during grace)
- Worst case: 18 min wasted work (vs 30 min without grace)
- Trade-off: Up to 18 min out-of-window bandwidth usage

**Why 60% of checkpoint interval:**
- Checkpoint interval = 30 min (Borg default, hardcoded)
- Average time to next checkpoint = 15 min (halfway through interval)
- 60% × 30 = 18 min covers most cases with reasonable buffer
- Not configurable - prevents users from breaking performance with short intervals

**Checkpoint Timing Behavior:**
- Borg 1.1+ creates checkpoints at chunk boundaries (2-4 MB chunks, process in seconds)
- Typical checkpoint drift: **30-34 minutes** (3-4 min variation due to chunk alignment)
- Grace period (18 min) sufficient for catching most checkpoint completions
- **Practical impact**: If backup runs past window end, expect termination within 3-4 minutes
- Edge case: Very large files with slow uploads may delay checkpoints to 35-40 min
- In edge cases: Grace expires before checkpoint → up to 30 min work lost (rare)

## Implementation Plan

### Phase 1: Window Monitor Script with Grace Period

**Files**: `scripts/window-monitor.sh` (new)

Create simple background monitor that terminates backup when window expires, with grace period optimization to allow checkpoint completion:

```bash
#!/bin/sh
# Monitor backup window and terminate if needed

BORG_PID=$1
CHECK_INTERVAL=60  # Check every minute

if [ -z "$BORG_PID" ]; then
    echo "ERROR: BORG_PID required"
    exit 1
fi

# Hardcoded checkpoint interval and grace period
# Borg default checkpoint interval is 1800s (30 min)
# Values < 1800s cause significant performance degradation (cache write storms)
# See: https://github.com/borgbackup/borg/issues/896
#      https://github.com/borgbackup/borg/issues/2841
CHECKPOINT_INTERVAL=1800  # 30 min (Borg upstream recommendation)
GRACE_PERIOD=1080         # 18 min (60% of checkpoint interval)

# Track when we exited window
WINDOW_EXIT_TIME=""

while kill -0 $BORG_PID 2>/dev/null; do
    sleep $CHECK_INTERVAL

    # Check if we're still in window
    if ! /scripts/check-window.sh; then
        # Outside window - check rate limit
        RATE_OUT="${BACKUP_RATE_LIMIT_OUT_WINDOW:--1}"

        if [ "$RATE_OUT" = "0" ]; then
            # Record when we first exited window
            if [ -z "$WINDOW_EXIT_TIME" ]; then
                WINDOW_EXIT_TIME=$(date +%s)
                echo "⚠️  Exited backup window, entering grace period (${GRACE_PERIOD}s)..."
                echo "Allowing time to complete current checkpoint..."
            fi

            # Check if grace period has expired
            CURRENT_TIME=$(date +%s)
            OVERRUN=$((CURRENT_TIME - WINDOW_EXIT_TIME))

            if [ "$OVERRUN" -ge "$GRACE_PERIOD" ]; then
                echo "⏹️  Grace period expired, terminating backup (PID: $BORG_PID)..."
                echo "Backup will auto-resume from checkpoint in next window"
                kill -TERM $BORG_PID
                exit 0
            fi
        fi
    else
        # Back in window (shouldn't happen, but reset if it does)
        WINDOW_EXIT_TIME=""
    fi
done
```

**Key design decisions:**
- Monitor checks every 60 seconds
- Grace period = 60% of `BORG_CHECKPOINT_INTERVAL` (default 18 min)
- Allows backup to continue past window end to complete checkpoint
- Minimizes wasted work (up to 30 min/day → near zero in most cases)
- Exits after terminating backup
- Only acts when `BACKUP_RATE_LIMIT_OUT_WINDOW=0`
- No state files needed

**Grace Period Rationale:**
- Without grace: Backup terminated at 06:30 loses 0-30 min of work since last checkpoint
- With 18 min grace: Backup has time to complete checkpoint, losing minimal work
- Trade-off: Up to 18 min of out-of-window bandwidth usage (acceptable)
- Fixed at 60% of Borg's recommended 30 min checkpoint interval

### Phase 2: Extract Window Check to Reusable Script

**Files**: `scripts/check-window.sh` (new)

Extract the `check_backup_window()` function to a standalone script for reuse:

```bash
#!/bin/sh
# Check if current time is within backup window
# Exit 0 if inside window, 1 if outside window

# If no window configured, always allow backup
if [ -z "$BACKUP_WINDOW_START" ] || [ -z "$BACKUP_WINDOW_END" ]; then
    exit 0
fi

# Convert HH:MM to HHMM for integer comparison
current=$(date +%H%M | sed 's/^0*//')
current=${current:-0}
start=$(echo "$BACKUP_WINDOW_START" | tr -d : | sed 's/^0*//')
start=${start:-0}
end=$(echo "$BACKUP_WINDOW_END" | tr -d : | sed 's/^0*//')
end=${end:-0}

# Normal window (e.g., 01:00-07:00)
if [ "$start" -lt "$end" ]; then
    if [ "$current" -ge "$start" ] && [ "$current" -lt "$end" ]; then
        exit 0  # Inside window
    else
        exit 1  # Outside window
    fi
else
    # Overnight window (e.g., 22:00-06:00)
    if [ "$current" -ge "$start" ] || [ "$current" -lt "$end" ]; then
        exit 0  # Inside window
    else
        exit 1  # Outside window
    fi
fi
```

### Phase 3: Update Backup Script

**Files**: `scripts/backup.sh`

Changes to spawn monitor with correct borg PID and handle termination:

```bash
# At the top, replace check_backup_window function with:
check_backup_window() {
    /scripts/check-window.sh
}

# Before borg create:
echo "Creating backup archive..."

# Spawn borg in background to capture its PID
# shellcheck disable=SC2086
borg create \
    --stats \
    --progress \
    --compression lz4 \
    $BORG_RATE_LIMIT \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    $PATHS &

BORG_PID=$!

# Verify we captured the correct PID (borg process)
if ! ps -p $BORG_PID -o comm= 2>/dev/null | grep -q "borg"; then
    echo "ERROR: Failed to start borg or capture PID"
    wait $BORG_PID
    exit $?
fi

echo "Borg process started (PID: $BORG_PID)"

# Spawn window monitor with verified borg PID
if [ "${BACKUP_RATE_LIMIT_OUT_WINDOW:-}" = "0" ]; then
    /scripts/window-monitor.sh $BORG_PID &
    MONITOR_PID=$!
    echo "Window monitor started (PID: $MONITOR_PID)"
fi

# Wait for borg to complete
wait $BORG_PID
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    # Success - checkpoint archives will be auto-cleaned by prune
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "✅ Backup completed successfully!"
    echo "Duration: ${DURATION}s"
    echo ""

    # Send success notification
    /scripts/notify.sh "backup.success" "INFO" \
        "Borg Backup Successful" \
        "Archive: ${ARCHIVE_NAME}, Duration: ${DURATION}s"

    # Run prune after backup
    echo "Running prune to clean up old archives..."
    /scripts/prune.sh

    echo "========================================="
    echo "Backup completed at $(date)"
    echo "========================================="

elif [ $EXIT_CODE -eq 143 ]; then
    # SIGTERM (killed by window monitor during grace period)
    echo ""
    echo "ℹ️  Backup terminated by window monitor"
    echo "Will resume from checkpoint in next window"
    echo ""
    exit 0  # Don't treat as failure

else
    # Genuine failure
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "✗ Backup failed!"
    echo ""

    # Send failure notification
    /scripts/notify.sh "backup.failure" "CRITICAL" \
        "Borg Backup Failed" \
        "Archive: ${ARCHIVE_NAME}, Exit code: ${EXIT_CODE}, Duration: ${DURATION}s"

    exit $EXIT_CODE
fi

# Monitor exits automatically when borg exits
```

**Key changes:**
- Run `borg create` in background with `&`
- Capture actual borg PID with `$!`
- Verify PID points to borg process (safety check)
- Pass verified PID to window monitor
- Use `wait` to capture borg exit code
- Handle exit code 143 (SIGTERM) as success

### Phase 4: Enhance Entrypoint Lock Handling

**Files**: `entrypoint.sh`

Update the AUTO_INIT section to auto-break locks on container restart:

```bash
# Auto-initialize repository if enabled and not exists
if [ "$AUTO_INIT" = "true" ]; then
    echo "Checking if repository exists..."

    # Try to list repository and capture output
    BORG_CHECK_OUTPUT=$(borg list "$BORG_REPO" 2>&1)
    BORG_CHECK_EXIT=$?

    if [ $BORG_CHECK_EXIT -eq 0 ]; then
        # Repository exists and is accessible
        echo "Repository already exists"

        # Check if key is exported, if not export it
        if [ ! -f /borg/config/repo-key.txt ]; then
            echo "Exporting repository key to /borg/config/repo-key.txt..."
            borg key export "$BORG_REPO" /borg/config/repo-key.txt
            echo "⚠️  Remember to backup /borg/config/repo-key.txt to password manager!"
        fi

    elif echo "$BORG_CHECK_OUTPUT" | grep -q "Lock.*by.*PID"; then
        # Repository is locked - container restart means previous backup is dead
        echo "⚠️  Repository locked from previous session, breaking lock..."
        borg break-lock "$BORG_REPO" 2>/dev/null || true
        echo "Lock broken - next backup will resume from checkpoint"

    else
        # Repository doesn't exist - initialize it
        echo ""
        echo "Repository not found - initializing automatically..."
        echo ""
        /scripts/init.sh
        echo ""
        echo "Repository initialized! Continuing with startup..."
        echo ""
    fi
    echo "========================================="
fi
```

**Key changes from current branch:**
- More aggressive lock breaking (container restart = safe to break)
- Relies on checkpoint feature for resume
- Clearer messaging about checkpoint resume

### Phase 5: Edge Cases & Testing

**Edge cases to handle:**

1. **Backup terminated when exiting window**:
   - Monitor sends SIGTERM to borg process
   - Script detects exit code 143 (SIGTERM), treats as success
   - Next window: borg auto-resumes from checkpoint

2. **Container restart during backup**:
   - Lock detected on startup → auto-break
   - Next cron run: borg auto-resumes from checkpoint

3. **Manual kill of borg process**:
   - Next cron run: may need to break lock
   - Borg auto-resumes from checkpoint

4. **Multi-day backup with daily windows**:
   - Day 1: Backup runs, terminated at window end
   - Day 2: Backup resumes from checkpoint, terminated again
   - Day N: Backup finally completes

5. **Window spans midnight** (e.g., 22:00-06:00):
   - Existing logic already handles this

6. **Unlimited rate during backup**:
   - Monitor not spawned when rate != 0
   - Backup runs to completion

**Test scenarios:**

```bash
# Test 1: Grace period allows checkpoint completion
# - Start backup at 01:00, window ends at 07:00, rate_out=0
# - At 06:45, checkpoint created
# - At 07:00, window ends → grace period starts (18 min)
# - At 07:10, next checkpoint created → backup terminated immediately
# - Expect: Minimal work lost, exit code 143 treated as success

# Test 2: Grace period expires before checkpoint
# - Start backup at 01:00, window ends at 07:00, rate_out=0
# - At 06:50, checkpoint created
# - At 07:00, window ends → grace period starts
# - At 07:18, grace period expires, no checkpoint yet → terminate
# - Expect: Max 18 min work lost, exit code 143 treated as success

# Test 3: Resume from checkpoint
# - Terminated backup from Test 1 or 2
# - Next cron trigger at 01:00 (inside window)
# - Expect: Borg detects checkpoint, resumes from where it left off

# Test 4: Container restart during backup
# - Start backup, restart container mid-backup
# - Expect: Lock broken on startup, next backup resumes from checkpoint

# Test 5: Multi-day backup with grace period
# - Large backup that takes 3 days with 6-hour windows
# - Each day: grace period allows checkpoint completion
# - Expect: Progresses ~6 hours/day, minimal re-work, completes on day 3

# Test 6: Unlimited rate during backup
# - Window expires but rate_out=-1
# - Expect: Backup continues without termination, no grace period
```

## Files Summary

**New files:**
- `scripts/window-monitor.sh` - Background monitor that terminates backup when window expires
- `scripts/check-window.sh` - Reusable window check script

**Modified files:**
- `entrypoint.sh` - Enhanced lock breaking on container restart
- `scripts/backup.sh` - Spawn monitor, handle SIGTERM exit code

**Documentation updates:**
- `README.md` - Document checkpoint-based resume behaviour
- `README.md` - Clarify rate limit semantics (0 = terminate and resume)

## Comparison: Old vs New Approach

| Aspect | Old (SIGSTOP/SIGCONT) | New (Checkpoint + Grace) |
|--------|----------------------|--------------------------|
| Pause mechanism | SIGSTOP signal | SIGTERM (kill) after grace period |
| Resume mechanism | SIGCONT signal | Borg auto-resume from checkpoint |
| State tracking | JSON state file with PID | None - Borg handles it |
| Container restart | Manual state cleanup | Auto-break lock, Borg resumes |
| Complexity | High (state mgmt, PID tracking) | Low (leverage Borg feature + grace timer) |
| Max work lost | None (paused in place) | Near-zero (grace period allows checkpoint completion) |
| Out-of-window time | None | Up to 18 min (grace period) |
| Reliability | Process must stay alive | Container-restart safe |

**Why the new approach is better:**
- ✅ Simpler implementation (less code, less complexity)
- ✅ Container-restart safe (no stale PIDs)
- ✅ Leverages Borg's native feature (battle-tested)
- ✅ No state files to manage
- ✅ Works across container restarts
- ✅ Grace period minimizes wasted work (near-zero vs up to 30 min/day)
- ⚠️ Up to 18 min out-of-window bandwidth (trade-off for simplicity + reliability)

## Design Decisions

### Checkpoint Interval & Grace Period
**Decision: Hardcode to Borg's recommended defaults**

- Checkpoint interval: **1800s (30 minutes)** - Borg upstream default
- Grace period: **1080s (18 minutes)** - 60% of checkpoint interval
- Not configurable via env vars

**Rationale:**
- Values < 1800s cause severe performance degradation (cache write storms, 2-5x slower)
- Borg team changed default from 300s→1800s due to user complaints
- Making it configurable invites users to break things
- References: [Borg #896](https://github.com/borgbackup/borg/issues/896), [#2841](https://github.com/borgbackup/borg/issues/2841)

### Notifications
**Decision: No new notifications for window enforcement events**

- Keep existing: SUCCESS (backup complete), FAILURE (errors)
- Don't add: Grace period entry, termination, resume
- Rationale: Multi-day backups would spam notifications (7+ per job)
- All events logged for debugging/troubleshooting

### Check Interval
**Decision: Hardcode CHECK_INTERVAL=60s**

- No env var, no configuration
- Good balance between responsiveness and CPU usage
- Users who override `BORG_CHECKPOINT_INTERVAL` should understand implications
- No validation - trust users to read docs

## Success Criteria

- [ ] Backup enters grace period when exiting window with rate=0
- [ ] Backup terminates after grace period expires (18 min default)
- [ ] Grace period allows checkpoint completion (minimizes wasted work)
- [ ] Terminated backup auto-resumes from checkpoint in next window
- [ ] Container restart recovers automatically (auto-break lock, resume from checkpoint)
- [ ] No manual intervention required for common scenarios
- [ ] Stale locks cleaned automatically on startup
- [ ] Existing behaviour preserved when window not configured
- [ ] Existing behaviour preserved when rate != 0
- [ ] Multi-day backups work correctly (progressive completion with minimal re-work)
- [ ] Grace period fixed at 18 min (60% of 30 min checkpoint interval)

## Dependencies

**Borg 1.1+ Required:**
- Borg 1.1+ introduces checkpoints within files (`.borg_part_<N>`)
- Borg 1.0.x only checkpoints at file boundaries (unacceptable drift)
- Docker image must use `borgbackup>=1.1`

## Related Issues & References

- Implements the design from issue #10 comment
- Builds on the lock detection added in `fix/auto-init-lock-handling` branch
- Borg checkpoint feature: [Issue #660](https://github.com/borgbackup/borg/issues/660)
- Checkpoint within files: [Issue #1198](https://github.com/borgbackup/borg/issues/1198)
- Checkpoint overhead: [Issue #896](https://github.com/borgbackup/borg/issues/896), [#2841](https://github.com/borgbackup/borg/issues/2841)
