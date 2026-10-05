# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are created automatically when a PR is merged to `main`; the version
bump is derived from the PR title (see [CONTRIBUTING.md](CONTRIBUTING.md)). Add
user-visible changes to `[Unreleased]` as part of your PR.

> **Upgrading?** Read the **Changed** entries. This is backup software - a
> behavioural change can mean archives are pruned, or a command you scripted
> now refuses to run.

## [Unreleased]

## [0.9.2] - 2026-10-05

### Fixed

- **Scheduled verification killed running backups.** `verify.sh` ran
  `borg break-lock` unconditionally before every check, on the reasoning that
  "verify takes priority". It does not: `break-lock` deletes the repository lock
  *and* the local cache lock, so a backup already in progress lost both and then
  died at its next checkpoint with `AssertionError: bug in code, exclusive lock
  should exist here`, followed by `NotLocked` on the cache it no longer owned.
  The backup exited 74 and the half-written archive was left for the next run to
  resume.

  This was not an edge case. Any backup that is still running when a check fires
  hit it, every time - a nightly backup at 01:00 that takes two hours and a
  weekly repository check at 03:00 collided every single week.

  A check now never interrupts a backup. It waits `VERIFY_LOCK_WAIT` seconds
  (300 by default) for the repository lock, and if it cannot get it, skips with a
  `verify.skipped` entry in the job history and runs on the next schedule. It
  never breaks the lock. Stale locks left by a container that died mid-backup are
  still cleared at startup by `entrypoint.sh`, which is the only place that can
  know the holder is really gone.

  Skips are deliberately visible rather than silent, because a check that keeps
  skipping is a check that is not happening: the startup preflight now reports a
  skipped job as a warning (`⚠ verify: SKIPPED at ... - did not run`) instead of
  a tick.

  A failure to acquire the lock is no longer reported as `verify.failure` - it is
  not a verification failure, because nothing was checked and nothing is known to
  be wrong. Repository corruption is still `verify.failure` with borg's exit
  code, unchanged.

### Changed

- **New `VERIFY_LOCK_WAIT`** (default `300`), the seconds a check waits for the
  repository lock before skipping. Nothing needs setting; the default covers a
  backup that is nearly done.

  **Check your verification schedules.** If `VERIFY_REPO_CRON_SCHEDULE` or
  `VERIFY_ARCHIVES_CRON_SCHEDULE` fires while your backup is typically still
  running, that check used to run (and break the backup) and will now skip
  instead. Move it clear of the backup window - the README examples now use
  06:00 rather than 03:00 for this reason.

## [0.9.1] - 2026-10-02

### Fixed

- **Job events were silently discarded.** `notify.sh` pushed every event to the
  TrueNAS API, which accepted the call and returned an ID but never surfaced the
  alert in the UI or triggered any notification service, because only predefined
  system alert classes do (#33). All sixteen call sites were no-ops - including
  `backup.failure` and `verify.failure`, so a nightly backup could fail for
  months, or `borg check` could detect corruption, and nothing would say so.

  Cron output only ever went to the container's stdout, which is lost to log
  rotation, a redeploy or an app update, so there was no durable record either.
  Unlike backups - where a stale "most recent archive" is ground truth you can
  query - a failed verify left no trace anywhere.

  `notify.sh` keeps its exact call signature, so every call site is unchanged,
  and now appends to `/borg/config/history.log` on the persisted config volume,
  one greppable event per line. Capped by `HISTORY_MAX_LINES` (500 by default,
  oldest dropped), roughly six months of a daily backup plus weekly checks.
  Writing is best-effort: a status line that cannot be written warns and exits 0
  rather than failing the backup.

  The startup preflight reads the history back and prints the last run of each
  job, flagging failures and counting any failure still present in the retained
  history - so a verify that found corruption stays visible even after a later
  run passes.

  **This container still does not push alerts anywhere.** It records what
  happened and you have to look, which is what it did in practice before, minus
  the misleading documentation. Push alerting remains open as #46 / #47.

### Removed

- **`NOTIFY_TRUENAS_ENABLED`, `NOTIFY_TRUENAS_API_URL`, `NOTIFY_TRUENAS_API_KEY`,
  `NOTIFY_TRUENAS_VERIFY_SSL` and `NOTIFY_EVENTS`**, along with the transport
  they configured. If you had any of them set you can delete them; leaving them
  set is harmless, they are simply ignored.

  `NOTIFY_EVENTS` has no replacement by design: the history file is a log, not
  an alert feed, and one that omitted successes could not answer "did the last
  backup work?". Every event is recorded.
- The README's Notifications section, which advertised the feature with
  working-looking setup instructions and so misled anyone pulling the published
  image into believing they had alerting.
- `curl` and `websocat` are no longer installed in the image; they existed only
  for the removed transport.
- `docs/truenas-api-key-setup.md`, which documented setting up the API key for
  notifications that could never arrive.

## [0.9.0] - 2026-10-02

### Added

- **Automated restore drills** (`scripts/restore-drill.sh`). Restores a rotating
  sample of real files from a real archive and compares them against the live
  source byte-for-byte (SHA-256). `borg check` proves the repository is
  structurally sound; a drill proves the data actually comes back. Configure
  with `RESTORE_DRILL_ENABLED` and `RESTORE_DRILL_CRON_SCHEDULE`, or run on
  demand with `/scripts/restore.sh drill`. Addresses #48.
- **Startup preflight / recovery-readiness report** (`scripts/preflight.sh`).
  Verifies the repository is reachable *and* that the configured passphrase
  actually decrypts the repository key, rather than assuming so until the next
  restore. Also reports passphrase source, SSH key mode, whether the repository
  key has been exported, and whether verification and drills are scheduled.
  Report-only by default; set `PREFLIGHT_STRICT=true` to fail fast, or
  `PREFLIGHT_ENABLED=false` to skip.
- **New `restore.sh` actions** (all additive):
  - `latest` - print the newest archive name
  - `files <archive> [pattern]` - find a file inside an archive
  - `dry-run <archive> [paths...]` - read and decrypt every chunk, writing nothing
  - `umount <path>` - counterpart to `mount`
  - `drill` - run a restore drill
  - `key-export [file]` - export the repository key for disaster recovery
- **Selective restores**: `extract <archive> [dest] [paths...]` accepts specific
  archive paths, so you can pull one file out of a multi-terabyte archive.
- **`latest` as an archive alias** for every action that takes an archive name.
  Borg 1.x has no `::latest` pseudo-archive, so it is resolved client-side via
  `borg list --last 1`.
- **Working `borg mount`**: the `borgbackup-fuse` package is now installed.
- This changelog, plus tooling to keep it honest: `auto-release.sh` promotes the
  `[Unreleased]` section to the released version at tag time, and a pre-merge CI
  check (`.github/scripts/check-changelog.sh`) fails a PR that adds no entry.
  The check is skipped for PRs that skip a release (`docs:`, `chore:`, `style:`,
  `test:`, `[SKIP]`) or carry the `no-changelog` label.
- New notification events `restore.success` and `restore.failure`.
- The container prints its version, Borg version and licence on start (#40).
- `/restore` directory in the image, for use as a restore mount point.

### Changed

- **Prune now runs after a fast backup.** Backups completing in under two
  seconds previously hit a faulty liveness check, exited early with status 0 and
  **silently skipped both prune and the success notification**. Retention was
  therefore not being enforced on small or fast repositories. After upgrading,
  the first backup on such a repository will prune according to
  `PRUNE_KEEP_DAILY` / `PRUNE_KEEP_WEEKLY` / `PRUNE_KEEP_MONTHLY` and may delete
  archives that were previously left in place. Review your retention settings
  before upgrading if that matters to you. (#56)
- **`restore.sh extract` refuses unsafe destinations.** Extracting to `/`, or to
  any path inside `BACKUP_PATHS`, now exits 1 instead of proceeding. Borg stores
  paths without a leading slash, so extracting at `/` recreates the original
  absolute tree and overwrites the very data being recovered. If you scripted
  `restore.sh extract <archive> /`, it will now fail - extract to a dedicated
  directory and move files back yourself.
- **`latest` is reserved as an archive name.** An archive literally named
  `latest` is shadowed by the alias resolution. Default archive names
  (`backup-<timestamp>`) are unaffected.
- `restore.sh mount` preflights FUSE support and reports the exact runtime flags
  required (`--device /dev/fuse --cap-add SYS_ADMIN
  --security-opt apparmor=unconfined`) instead of failing with a bare
  `FUSE mount failed`. Set `RESTORE_SKIP_FUSE_CHECK=true` to bypass the probe.
- Unit test failures now gate CI. The bats matrix ran with
  `continue-on-error: true`, so the Tests check reported success even when tests
  failed.

### Fixed

- `restore.sh extract` no longer accepts a destination that resolves to `/`.
  The destination guard only rejected the literal `/`, but the default is `.`
  and the image sets no working directory, so
  `docker exec … /scripts/restore.sh extract latest` ran with a working
  directory of `/` and recreated the archive tree over the live filesystem.
  Destinations are now normalised (relative paths, `..` segments) before being
  checked, and `BACKUP_PATHS` entries are normalised too, so a trailing slash
  or a `BACKUP_PATHS=/` no longer bypasses the guard.
- The restore drill no longer deletes an unvalidated directory.
  `RESTORE_DRILL_TARGET` was `rm -rf`'d on every run, so pointing it at a
  mounted restore directory erased that directory, and pointing it inside
  `BACKUP_PATHS` deleted live source data on a schedule. The drill now refuses
  an unsafe target and confines itself to a per-run subdirectory it creates.
- A borg *warning* from `borg extract` (such as unsupported xattrs or ACLs on
  the restore target) no longer aborts a drill and raises a CRITICAL
  "backups may not be recoverable" alert. Warnings are reported and
  verification still decides the outcome.
- `BORG_PASSPHRASE_FILE` pointing at a missing file is now a startup error.
  It was silently ignored, so a forgotten or mistyped secret mount kept working
  from a leftover `BORG_PASSPHRASE` - defeating the point of using a file.
- The startup preflight no longer runs `borg info`, whose cache statistics force
  a chunks-cache sync that can block startup for a long time on a large
  repository. `borg list --last 1` proves the passphrase decrypts the key
  without touching the cache.
- A non-numeric `RESTORE_DRILL_SAMPLE_COUNT` is reported as a configuration
  error instead of dividing by zero and surfacing as a failed drill.
- `restore.sh files <archive> <pattern>` exits 0 and explains itself when
  nothing matches, instead of exiting 1 as though the repository had failed.
- Preflight no longer claims "AUTO_INIT=false will create it" for a missing
  repository; that case is now reported as a problem.
- `scripts/preflight.sh` and `scripts/restore-drill.sh` are committed
  executable, so they run from a git checkout and not only from the image.
- The `no-changelog` label now actually clears the changelog check - the
  workflow did not trigger on label changes.
- The changelog gate and the release workflow now apply the same skip rules, so
  a release can no longer ship an empty `[Unreleased]` section. `pr-release.yml`
  also had an unbracketed `&&`/`||` chain that made `[SKIP] bump deps` and
  `docs: update deps` release anyway, and interpolated the PR title directly
  into a shell script.
- Fast (<2s) backups no longer print a misleading
  `ERROR: Failed to start borg or capture PID`, and no longer skip prune and the
  success notification. (#56)
- `backup.sh` error handling now actually runs on failure. `set -e` aborted the
  script when `wait` returned non-zero, so the failure branch - including the
  `backup.failure` notification - was unreachable. This had been masked by two
  skipped tests, which are now enabled.
- `borg mount` works at all. It was documented in the README but the Alpine
  `borgbackup` package ships no FUSE bindings, so it always failed with
  `no FUSE support, BORG_FUSE_IMPL=pyfuse3,llfuse`.

### Documentation

- New **Recovery** section: quick-reference table for every restore operation,
  selective restores, FUSE mount requirements, restore drills and preflight.
- Corrected guidance that suggested `restore.sh check` was a way to "test
  restores" - it verifies repository structure and never reads file data.
- Design notes in `docs/20261002-recovery-flow.md`.
- Linked BorgBackup's source repository and recorded the pinned Borg version.

## [0.8.0] - 2026-10-02

### Added

- Passphrase can be supplied from a file (`BORG_PASSPHRASE_FILE`) or a command
  (`BORG_PASSCOMMAND`) instead of a plain environment variable, keeping the
  secret off the unencrypted TrueNAS apps pool. (#53, #55)

## [0.7.0] - 2026-06-20

### Added

- `BACKUP_EXCLUDES` for excluding paths from a backup.
- End-to-end test suite against a real Borg SSH server.
- `env_file` support in the Compose setup.

### Changed

- `CRON_SCHEDULE` is now optional; omit it for on-demand-only operation. (#54)
- Release notes list commit messages. (#50)

## [0.6.2] - 2026-02-16

### Fixed

- Integration tests exercise the wrapper scripts rather than borg directly. (#49)

## [0.6.1] - 2026-02-15

### Fixed

- Verification schedules are optional, with no implicit defaults. (#45)

## [0.6.0] - 2026-02-15

### Added

- Scheduled repository integrity verification via `borg check`, with
  `repository`, `archives` and `full` levels. (#44)

## [0.5.7] - 2026-02-14

### Fixed

- Lock handling failures on startup and during backups. (#42, #43)

## [0.5.6] - 2026-01-25

### Fixed

- TrueNAS notification response parsing. (#41)

## [0.5.5] - 2026-01-25

### Added

- bats unit test suite. (#34)

## [0.5.4] - 2026-01-25

### Fixed

- TrueNAS WebSocket authentication for notifications. (#32)

## [0.5.3] - 2026-01-22

### Fixed

- TrueNAS SCALE 25.04+ notifications via the WebSocket API. (#31)

## [0.5.2] - 2026-01-20

### Changed

- Enabled Borg modern exit codes (`BORG_EXIT_CODES=modern`) for more specific
  error reporting. (#30)

## [0.5.1] - 2026-01-19

### Fixed

- Cache lock handling during repository initialisation. (#16)

---

Entries for 0.5.0 and earlier are not reconstructed here; see the
[release history](https://github.com/DiarmuidKelly/docker-borg-client/releases)
and `git log`.

[Unreleased]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.7...v0.6.0
[0.5.7]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.6...v0.5.7
[0.5.6]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.5.0...v0.5.1
