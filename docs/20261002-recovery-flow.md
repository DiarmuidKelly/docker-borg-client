# Recovery Flow and Fail-Safes

**Date:** 2026-10-02
**Status:** Implemented
**Related issues:** #56 (fixed), #48 (addressed), #40 (addressed), #25 (partly addressed)

## Motivation

Backups had been running reliably in production for months (37 TB across all
archives, ~2.25 TB per archive) and `borg check` passed. But a restore had
never actually been performed. That gap is the classic one: the backup side was
well covered by tests and scheduling, while the recovery side was a thin wrapper
and some README prose.

Three concrete problems were found while reviewing the recovery path:

1. **`borg mount` could not work at all.** The README documented
   `/scripts/restore.sh mount` in two places, but the Alpine `borgbackup`
   package ships no FUSE bindings, so it failed with
   `no FUSE support, BORG_FUSE_IMPL=pyfuse3,llfuse`. Mounting is the only
   practical way to pick a handful of files out of a 2.25 TB archive, so the
   documented recovery path for the most likely scenario was broken.

2. **Recoverability was never proven, only assumed.** `borg check --repository-only`
   verifies repository structure. It does not read file data, and it cannot tell
   you whether the configured passphrase still decrypts the key or whether a
   restored file matches its source.

3. **A fast backup silently skipped prune and notifications** (#56). The
   `sleep 2` + `kill -0` liveness probe could not distinguish "borg failed to
   start" from "borg already finished", so sub-2-second backups exited 0 early.

## What was built

### 1. A real recovery toolkit (`scripts/restore.sh`)

Extended from 5 actions to 11, with `latest` resolution available everywhere
(Borg 1.x has no `::latest` pseudo-archive, so it is resolved client-side with
`borg list --last 1`):

| Action | Purpose |
|--------|---------|
| `list` | List archives (unchanged) |
| `latest` | Print the newest archive name (scriptable) |
| `info` | Archive details (unchanged, now accepts `latest`) |
| `files <archive> [pattern]` | Find a file inside an archive |
| `extract <archive> [dest] [paths...]` | Restore everything, or only named paths |
| `dry-run <archive> [paths...]` | Read and decrypt every chunk, write nothing |
| `mount` / `umount` | Browse an archive as a filesystem |
| `check` | Repository integrity (unchanged) |
| `drill` | Run an automated restore drill |
| `key-export` | Export the repository key for disaster recovery |

`dry-run` matters for large repositories: it proves an archive is fully
readable without needing the disk space to restore it.

### 2. Automated restore drills (`scripts/restore-drill.sh`)

Issue #48 proposed *reminders* to perform a manual test restore. A reminder
still depends on a human acting on it, so this implements the drill itself:

1. Resolve the archive (newest by default).
2. List contents via `borg list --json-lines`, keeping regular, non-empty files
   under `RESTORE_DRILL_MAX_FILE_BYTES` (100 MB default).
3. Select `RESTORE_DRILL_SAMPLE_COUNT` files, rotating the selection by
   day-of-year so successive drills cover different data while staying
   reproducible for a given day.
4. Restore just those paths.
5. Compare each restored file against the live source with SHA-256.
6. Report and notify (`restore.success` / `restore.failure`).

Design decisions worth recording:

- **Never break a lock.** A drill is lower priority than a backup. It passes
  `--lock-wait` and, if the repository is still locked, *skips* the run and
  exits 0 rather than failing or breaking the lock. This deliberately differs
  from `verify.sh`, which does break locks.
- **A changed source file is not a failure.** Borg verifies chunk hashes during
  extract, so a restored file that differs from the current source means the
  source changed since the backup — normal. Only an unreadable, missing or
  empty file fails the drill.
- **Sampling, not full restore.** A full restore of a multi-terabyte repository
  is not something you can schedule quarterly. Rotating samples give
  broadening coverage over time at negligible cost.
- **It lives in `scripts/`, not `tests/`.** It is a scheduled production
  operation that ships in the image for cron to run, like `verify.sh` and
  `prune.sh`. Its unit tests are in `tests/restore-drill.bats`.

### 3. Startup preflight (`scripts/preflight.sh`)

Reports recovery readiness on every start. The important check is
`borg info --json`, which proves the configured passphrase actually decrypts the
repository key — previously that was only discovered during a real restore.
Also flags: passphrase source (env var vs file vs command), SSH key presence
and mode, whether the repository key has been exported, whether archives exist,
and whether scheduled verification and drills are enabled.

Report-only by default. A backup container that refuses to start because the
network blipped is worse than one that warns and retries on schedule;
`PREFLIGHT_STRICT=true` opts into fail-fast.

### 4. Fail-safes

- **Never restore over live data.** Borg stores paths without a leading slash,
  so extracting at `/` recreates the original absolute tree and overwrites the
  source. `extract` refuses `/` and any destination inside `BACKUP_PATHS`, and
  warns when the destination is non-empty.
- **FUSE preflight.** `mount` checks for the pyfuse3/llfuse bindings and
  `/dev/fuse` and prints the exact flags needed
  (`--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined`)
  instead of a bare `FUSE mount failed`.
- **`borgbackup-fuse` added to the image**, so mounting works at all.
- **Issue #56 fixed.** The liveness probe is gone; `wait` is the authoritative
  source of borg's exit code, guarded by `set +e` so the error handling can run.
- **Unit tests now gate CI.** `test.yml` had `continue-on-error: true`, so the
  suite reported green even when tests failed. Removed.

## Verification

- 201 bats unit tests pass, with no skips. Two previously skipped tests
  (`handles backup failure correctly`, `handles SIGTERM as window termination`)
  were un-skipped: their FIXME described the exact `set -e` bug fixed here.
- E2E suite drives the full flow against a real Borg SSH server, including a
  drill that byte-compares restored files to the source and a drill that is
  expected to fail.
- `borg mount` verified manually end to end: mount, `ls`, read a file, unmount.

## Notes and follow-ups

- Alpine 3.24 community packages Borg **1.4.4**; upstream stable is **1.4.5**.
  The pin cannot move until Alpine updates. `ARG BORG_VERSION` is commented
  accordingly.
- Issue #48's suggested `::latest` syntax does not exist in Borg 1.x — hence
  client-side `latest` resolution.
- Still open: #24 (free-space file on remote), #19 (QR of the repo key),
  #46/#47 (notification providers). Drills currently surface through the
  existing TrueNAS dispatcher only.
- `verify.sh` breaking locks is a documented hazard (#25). The drill's
  lock-respecting behaviour is the counter-example to follow if that is revised.
