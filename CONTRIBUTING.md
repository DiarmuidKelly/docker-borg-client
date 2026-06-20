# Contributing

Contributions are welcome. Please open an issue to discuss significant changes before submitting a pull request.

## Development Setup

### Building

```bash
docker build -t docker-borg-client .
```

Quick smoke-test a script against a local repo:

```bash
docker run --rm -it \
  -e BORG_REPO=ssh://user@host:22/./backup \
  -e BORG_PASSPHRASE=testpass \
  -e BACKUP_PATHS=/data \
  -v /path/to/data:/data:ro \
  -v ./ssh:/ssh:ro \
  docker-borg-client /scripts/backup.sh
```

## Testing

### Linting

All shell scripts are checked with [shellcheck](https://www.shellcheck.net/) (the same check CI runs):

```bash
make lint     # shellcheck every *.sh
make check    # lint + unit tests - the quick pre-push gate
```

### Unit Tests

All shell scripts are covered by [bats-core](https://github.com/bats-core/bats-core) unit tests.

**Install bats:**

macOS:
```bash
brew install bats-core
```

Ubuntu/Debian:
```bash
sudo apt-get install bats
```

Other:
```bash
git clone https://github.com/bats-core/bats-core.git && cd bats-core && ./install.sh /usr/local
```

**Run:**

```bash
make test              # run locally with bats
make test-alpine       # run inside Alpine Docker container (CI-equivalent)
```

Run a single file:
```bash
bats tests/backup.bats
```

**Coverage:**

| File | Tests |
|------|-------|
| `auto-release.bats` | Container startup behaviour |
| `backup.bats` | Backup execution, rate limiting, excludes |
| `check-window.bats` | Backup window time checking |
| `entrypoint.bats` | Lock handling, cron setup |
| `init.bats` | Repository initialisation |
| `notify.bats` | Notification system |
| `prune.bats` | Archive pruning logic |
| `restore.bats` | Restore operations |
| `verify.bats` | Repository integrity verification |
| `window-monitor.bats` | Window monitoring and backup termination |

### End-to-End Tests

E2E tests spin up a real Borg SSH server alongside the client container and exercise a full backup → verify → restore cycle. Docker and Docker Compose v2 are required.

```bash
make test-e2e
```

This will:
1. Generate a temporary SSH key pair
2. Build the client image and a minimal borg-server image
3. Run a backup with `AUTO_INIT=true` and `RUN_ON_START=true`
4. Verify the archive exists and excluded paths are absent
5. Restore files and assert they match the originals
6. Tear everything down

Unit tests run on every push and pull request via GitHub Actions. E2E tests run as part of the release workflow.
