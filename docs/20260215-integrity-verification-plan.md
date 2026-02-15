# Plan: Implement Repository Integrity Verification (Issue #12)

## Overview
Add scheduled `borg check` verification with configurable levels to docker-borg-client.

## Files to Create/Modify

### 1. Create `scripts/verify.sh` (new file)
Follow `prune.sh` pattern:
- `#!/bin/sh` with `set -e`
- **Break any existing lock first** — verify takes priority; interrupted backups resume from checkpoint on next run
- Default `VERIFY_LEVEL="${VERIFY_LEVEL:-repository}"`
- Logging with `=========` separators
- Case statement for verification levels:
  - `repository` → `borg check --repository-only --progress`
  - `archives` → `borg check --archives-only --progress`
  - `full` → `borg check --verify-data --progress` (manual use only — very slow)
- Duration tracking with `START_TIME`/`END_TIME`
- Notifications: `verify.success` / `verify.failure`
- **No window monitoring** — verify is read-only, doesn't impact upload bandwidth

### 2. Modify `entrypoint.sh`
After line 21 (defaults section), add:
```sh
VERIFY_ENABLED="${VERIFY_ENABLED:-false}"
VERIFY_CRON_SCHEDULE="${VERIFY_CRON_SCHEDULE:-0 3 1 * *}"
```

After line 110 (cron setup), add:
```sh
if [ "$VERIFY_ENABLED" = "true" ]; then
    echo "$VERIFY_CRON_SCHEDULE /scripts/verify.sh >> /proc/1/fd/1 2>&1" >> /etc/crontabs/root
    echo "Verification cron job configured"
fi
```

### 3. Create `tests/verify.bats` (new file)
Follow `prune.bats` pattern with test cases:
1. Default level (repository) verification succeeds
2. Archives level uses `--archives-only`
3. Full level uses `--verify-data`
4. Invalid level exits with error
5. Verification failure sends `verify.failure` notification
6. Progress flag is always used
7. Repository path passed correctly
8. Duration included in notification

### 4. Add tests to `tests/entrypoint.bats`
- Test verification cron configured when `VERIFY_ENABLED=true`
- Test verification cron NOT configured when `VERIFY_ENABLED=false`
- Test default schedule `0 3 1 * *`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VERIFY_ENABLED` | `false` | Enable scheduled verification (set `true` to enable) |
| `VERIFY_CRON_SCHEDULE` | `0 3 1 * *` | Cron schedule (default: 1st of month at 03:00) |
| `VERIFY_LEVEL` | `repository` | Check depth: `repository`, `archives`, `full` |

**Notes:**
- Verify breaks any existing borg lock before running — if a backup is in progress, it will be interrupted and resume from checkpoint on next scheduled run
- Verify does not respect the backup window (read-only operation, no upload bandwidth impact)
- `full` level (`--verify-data`) reads all data and is very slow on large repos — use for manual spot-checks only

## Verification

1. **Run tests:**
   ```bash
   bats tests/verify.bats
   bats tests/entrypoint.bats
   ```

2. **Manual test with small repo:**
   ```bash
   # Test each level
   VERIFY_LEVEL=repository ./scripts/verify.sh
   VERIFY_LEVEL=archives ./scripts/verify.sh
   VERIFY_LEVEL=full ./scripts/verify.sh
   ```

3. **Test in container:**
   ```bash
   docker compose up -d
   docker compose exec borg /scripts/verify.sh
   ```

4. **Once working, run against 1.5TB backup:**
   ```bash
   VERIFY_LEVEL=repository ./scripts/verify.sh  # Start with fast check
   ```
