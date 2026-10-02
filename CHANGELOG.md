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

[Unreleased]: https://github.com/DiarmuidKelly/docker-borg-client/compare/v0.8.0...HEAD
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
