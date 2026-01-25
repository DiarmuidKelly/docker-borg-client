# Docker Borg Client

[![Docker Image Version](https://img.shields.io/docker/v/diarmuidk/docker-borg-client?sort=semver&logo=docker)](https://hub.docker.com/r/diarmuidk/docker-borg-client)
[![Docker Image Size](https://img.shields.io/docker/image-size/diarmuidk/docker-borg-client/latest?logo=docker)](https://hub.docker.com/r/diarmuidk/docker-borg-client)
[![Docker Pulls](https://img.shields.io/docker/pulls/diarmuidk/docker-borg-client?logo=docker)](https://hub.docker.com/r/diarmuidk/docker-borg-client)
[![Docker Stars](https://img.shields.io/docker/stars/diarmuidk/docker-borg-client?logo=docker)](https://hub.docker.com/r/diarmuidk/docker-borg-client)
[![CI](https://github.com/DiarmuidKelly/docker-borg-client/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/DiarmuidKelly/docker-borg-client/actions)
[![Tests](https://github.com/DiarmuidKelly/docker-borg-client/actions/workflows/test.yml/badge.svg)](https://github.com/DiarmuidKelly/docker-borg-client/actions/workflows/test.yml)
[![GitHub release](https://img.shields.io/github/v/release/DiarmuidKelly/docker-borg-client?logo=github)](https://github.com/DiarmuidKelly/docker-borg-client/releases)
[![Licence](https://img.shields.io/github/license/DiarmuidKelly/docker-borg-client)](LICENCE)

A minimal, generic Docker container for running [BorgBackup](https://www.borgbackup.org/) backups to any remote SSH-accessible Borg repository. Designed for TrueNAS but works anywhere Docker runs.

## Overview

**Why Docker Borg Client?**

If you're running a home server, NAS, or any system with important data, you need reliable, automated backups. This container solves the "backup problem" with a production-ready solution that just works:

- **Set it and forget it** - Configure once, runs forever. Automated backups on your schedule with smart retention policies that keep recent backups while pruning old ones.
- **Production Upstream technology** - Built on [BorgBackup](https://www.borgbackup.org/), used by thousands for petabytes of data. Provides deduplication, compression, and encryption that can reduce backup sizes by 95%+.
- **Cost-effective** - Works with any SSH-accessible storage: a Raspberry Pi at a friend's house, cloud hosting provider, or any VPS. No vendor lock-in.
- **TrueNAS optimized** - Built for the TrueNAS ecosystem - but in theory should run on an docker enginer.
- **Recovery focused** - Your backups are only as good as your ability to restore. Includes comprehensive restore tools and disaster recovery documentation. Every backup is encrypted client-side - even if your backup server is compromised, your data remains safe.

**Perfect for:**
- Home lab enthusiasts backing up Docker volumes, databases, and configuration
- TrueNAS users wanting automated off-site backups of their datasets
- Small businesses needing GDPR-compliant encrypted backups
- Anyone who learned the hard way that RAID is not a backup

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [TrueNAS SCALE Setup](#truenas-scale-setup)
  - [Docker Compose Setup](#docker-compose-setup)
- [Configuration Reference](#configuration-reference)
  - [Environment Variables](#environment-variables)
  - [Notification Variables](#notification-variables-optional)
  - [Backup Time Window and Rate Limiting](#backup-time-window-and-rate-limiting-optional)
  - [Volume Mounts](#volume-mounts)
- [Manual Operations](#manual-operations)
- [Docker Compose Example](#docker-compose-example)
- [Additional Guides](#additional-guides)
- [Cron Schedule Examples](#cron-schedule-examples)
- [Notifications](#notifications)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Security Best Practices](#security-best-practices)
- [Disaster Recovery](#disaster-recovery)
- [Development](#development)
- [Contributing](#contributing)
- [Licence](#licence)
- [Acknowledgements](#acknowledgements)

## Features

- 🔒 **Secure**: Client-side encryption with SSH key authentication
- 🐧 **Minimal**: Alpine Linux + Borg + SSH client only
- 🔧 **Generic**: Works with any Borg-over-SSH target (Hetzner, rsync.net, self-hosted)
- 📅 **Automated**: Configurable cron-based scheduled backups
- ♻️ **Smart retention**: Automatic pruning with configurable policies
- 🏗️ **Multi-arch**: Supports amd64 and arm64

## Quick Start

### Prerequisites

1. A remote Borg repository accessible via SSH (see [Provider Guides](#provider-specific-guides))
2. SSH key pair for authentication
3. Docker and Docker Compose installed (or TrueNAS SCALE)

### TrueNAS SCALE Setup

TrueNAS SCALE users can deploy this container using the **Custom App** feature:

1. **Prepare SSH Keys**:
   - Create a directory for your SSH keys:
     ```bash
     mkdir -p /mnt/pool/borg-backup/ssh
     ssh-keygen -t ed25519 -f /mnt/pool/borg-backup/ssh/key -N ""
     chmod 700 /mnt/pool/borg-backup/ssh
     chmod 600 /mnt/pool/borg-backup/ssh/key
     ```
   - Add the public key to your remote backup server:
     ```bash
     cat /mnt/pool/borg-backup/ssh/key.pub
     ```

2. **Deploy Custom App**:
   - Navigate to **Apps** → **Discover Apps** → **Custom App**
   - Click **Install** on Custom App
   - Configure the following:

   **Application Name**: `borg-backup`

   **Image Configuration**:
   - Image Repository: `diarmuidk/docker-borg-client`
   - Image Tag: `latest`
   - Image Pull Policy: `Always`

   **Container User and Group** (under Advanced Settings):
   - User ID: `0`
   - Group ID: `0`

   > **Note**: This container runs as root (UID/GID 0:0) to ensure reliable access to all backup paths. Backup containers require broad filesystem access by design. Privileged mode is not required.

   **Environment Variables** (Required - add all of these):
   ```
   BORG_REPO=ssh://user@your-backup-server.com:22/~/backups
   BORG_PASSPHRASE=your-strong-passphrase-here
   BACKUP_PATHS=/data/dataset1:/data/dataset2
   CRON_SCHEDULE=0 2 * * 0
   PRUNE_KEEP_DAILY=7
   PRUNE_KEEP_WEEKLY=4
   PRUNE_KEEP_MONTHLY=6
   AUTO_INIT=true
   ```

   > **Note**: Set timezone using TrueNAS's built-in **Timezone** dropdown (under Advanced Settings), not as an environment variable.

   **Optional - Time Window Configuration** (for large initial backups):
   ```
   BACKUP_WINDOW_START=01:00
   BACKUP_WINDOW_END=07:00
   BACKUP_RATE_LIMIT_IN_WINDOW=-1
   BACKUP_RATE_LIMIT_OUT_WINDOW=0
   ```
   This configuration runs backups only during 1am-7am at full speed, perfect for large initial backups on limited connections.

   **Storage**:
   - Add **Host Path Volume** for SSH keys:
     - Host Path: `/mnt/pool/borg-backup/ssh`
     - Mount Path: `/ssh`
     - Read Only: ✅ Enable

   - Add **Host Path Volume** for each dataset to backup:
     - Host Path: `/mnt/pool/your-dataset`
     - Mount Path: `/data/dataset1`
     - Read Only: ✅ Enable

   - Add **ixVolume** for Borg cache:
     - Mount Path: `/borg/cache`

   - Add **ixVolume** for Borg config:
     - Mount Path: `/borg/config`

   **Restart Policy**: `Unless Stopped`

3. **Initialize Repository**:

   **Option A - Automatic (Recommended)**:
   - Add `AUTO_INIT=true` to environment variables
   - Start the app - repository will be automatically initialized on first run
   - Check logs to see initialization message and **backup the credentials**
   - Navigate to **Apps** → **Installed** → **borg-backup** → **Shell**
   - Run: `cat /borg/config/repo-key.txt` and save to password manager

   **Option B - Manual**:
   - After deployment, access the container shell via TrueNAS web UI
   - Navigate to **Apps** → **Installed** → **borg-backup** → **Shell**
   - Run: `/scripts/init.sh`
   - **Backup your passphrase and the repository key** to password manager

4. **Monitor Backups**:
   - View logs: **Apps** → **Installed** → **borg-backup** → **Logs**
   - Backups will run automatically according to your cron schedule

#### TrueNAS-Specific Notes

**Timezone Configuration:**
- **Do NOT add `TZ` as a manual environment variable** in TrueNAS Custom Apps
- TrueNAS automatically manages timezone - look for a **Timezone** dropdown in the app configuration
- Adding `TZ` manually will cause deployment errors: `Environment variable [TZ] is already defined`

**SSH Key Permissions:**
- Private key must be `600` (read/write for owner only)
- SSH directory must be `700` (read/write/execute for owner only)
- If permissions are incorrect, SSH authentication will silently fail

**Testing SSH Connection:**

Before deploying, verify SSH key authentication works:
```bash
ssh -i /mnt/pool/borg-backup/ssh/key -p <port> user@backup-server.com
```

If prompted for password, SSH key is not configured correctly on remote server.

### Docker Compose Setup

1. **Generate SSH keys** (if you don't have them):
   ```bash
   mkdir -p ssh
   ssh-keygen -t ed25519 -f ssh/key -N ""
   ```

2. **Add the public key to your backup server**:
   ```bash
   cat ssh/key.pub
   # Copy this and add it to ~/.ssh/authorized_keys on your backup server
   ```

3. **Configure environment**:
   ```bash
   cp .env.example .env
   # Edit .env with your settings
   ```

4. **Initialize the Borg repository** (one-time):
   ```bash
   docker compose run --rm borg-backup /scripts/init.sh
   ```

5. **Start the backup container**:
   ```bash
   docker compose up -d
   ```

## Configuration Reference

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BORG_REPO` | Yes | - | Full SSH URL to repository (e.g., `ssh://user@host:22/~/backup`) |
| `BORG_PASSPHRASE` | Yes | - | Repository encryption passphrase |
| `BACKUP_PATHS` | Yes | - | Colon-separated paths to back up (e.g., `/data/photos:/data/docs`) |
| `BORG_RSH` | No | `ssh -i /ssh/key -o StrictHostKeyChecking=accept-new` | SSH command |
| `CRON_SCHEDULE` | No | `0 2 * * 0` | Cron expression (default: Sunday 2am) |
| `RUN_ON_START` | No | `false` | Run backup immediately on container start |
| `AUTO_INIT` | No | `false` | Automatically initialize repository if it doesn't exist |
| `PRUNE_KEEP_DAILY` | No | `7` | Daily archives to keep |
| `PRUNE_KEEP_WEEKLY` | No | `4` | Weekly archives to keep |
| `PRUNE_KEEP_MONTHLY` | No | `6` | Monthly archives to keep |
| `TZ` | No | `UTC` | Timezone for cron jobs |

#### Notification Variables (Optional)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NOTIFY_TRUENAS_ENABLED` | No | `false` | Enable TrueNAS API notifications |
| `NOTIFY_TRUENAS_API_URL` | No | - | TrueNAS WebSocket URL (e.g., `ws://192.168.1.100` or `wss://truenas.local`) |
| `NOTIFY_TRUENAS_API_KEY` | No | - | TrueNAS API key (generate in Settings → API Keys) |
| `NOTIFY_TRUENAS_VERIFY_SSL` | No | `true` | Verify SSL certificates for wss:// (set to `false` for self-signed) |
| `NOTIFY_EVENTS` | No | `backup.failure,prune.failure` | Comma-separated list of events to notify |

**Available Events**: `backup.success`, `backup.failure`, `prune.success`, `prune.failure`, `container.startup`, `container.shutdown`

See [TrueNAS API Key Setup Guide](docs/truenas-api-key-setup.md) for detailed instructions.

#### Backup Time Window and Rate Limiting (Optional)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKUP_WINDOW_START` | No | - | Start of backup window in HH:MM format (e.g., `01:00`) |
| `BACKUP_WINDOW_END` | No | - | End of backup window in HH:MM format (e.g., `07:00`) |
| `BACKUP_RATE_LIMIT_IN_WINDOW` | No | `-1` | Rate limit during window in Mbps (`-1` = unlimited) |
| `BACKUP_RATE_LIMIT_OUT_WINDOW` | No | `-1` | Rate limit outside window in Mbps (`0` = stopped, `-1` = unlimited) |

**Rate Limit Values:**
- `-1` = Unlimited bandwidth (burst speeds)
- `0` = Terminate backup outside window, auto-resume from checkpoint (only valid for `BACKUP_RATE_LIMIT_OUT_WINDOW`)
- Positive number = Bandwidth limit in Mbps (e.g., `40` = 40 Mbps)

**Use Cases:**

1. **Large initial backup on limited connection** (e.g., 1.5TB on 40 Mbps):
   ```bash
   BACKUP_WINDOW_START=01:00
   BACKUP_WINDOW_END=07:00
   BACKUP_RATE_LIMIT_IN_WINDOW=-1    # Unlimited overnight
   BACKUP_RATE_LIMIT_OUT_WINDOW=0    # Terminated and resumed via checkpoint
   ```
   - Backup runs at full speed during 1am-7am window
   - Automatically terminated at 7am (checkpoint polling in final 30 min)
   - Resumes next night from last checkpoint
   - Completes 1.5TB in 3-4 nights with minimal rework

2. **Continuous backup with daytime throttle**:
   ```bash
   BACKUP_WINDOW_START=22:00
   BACKUP_WINDOW_END=08:00
   BACKUP_RATE_LIMIT_IN_WINDOW=-1    # Unlimited overnight
   BACKUP_RATE_LIMIT_OUT_WINDOW=5    # 5 Mbps trickle during day
   ```

3. **Daytime backup with bandwidth limit**:
   ```bash
   BACKUP_WINDOW_START=09:00
   BACKUP_WINDOW_END=17:00
   BACKUP_RATE_LIMIT_IN_WINDOW=20    # 20 Mbps during business hours
   BACKUP_RATE_LIMIT_OUT_WINDOW=0    # Terminated outside business hours
   ```

**How It Works:**
- Borg (1.1+) automatically creates checkpoints every 30 minutes during backup
- When backup window ends with `BACKUP_RATE_LIMIT_OUT_WINDOW=0`:
  - Monitor polls for new checkpoints in final 30 minutes of window
  - If new checkpoint detected → backup terminated immediately (minimizes wasted work)
  - If window ends → backup terminated at deadline (hard stop)
  - **Zero out-of-window bandwidth usage** (never exceeds window)
- Next backup run automatically resumes from last checkpoint
- Container restarts automatically break stale locks and resume from checkpoint
- No manual intervention required

**Requirements:**
- Borg 1.1 or later (for checkpoint support within files)

### Volume Mounts

| Container Path | Purpose | Mode |
|----------------|---------|------|
| `/data` | Source directories to back up | read-only |
| `/ssh` | SSH private key | read-only |
| `/borg/cache` | Borg cache (improves performance) | read-write |
| `/borg/config` | Borg config persistence | read-write |

## Manual Operations

### TrueNAS SCALE

All manual operations can be performed via the container shell in the TrueNAS web UI:

**Access Shell**: **Apps** → **Installed** → **borg-backup** → **Shell**

Then run any of the following commands:

- **List backups**: `/scripts/restore.sh list`
- **View archive info**: `/scripts/restore.sh info backup-2026-01-18_12-00-00`
- **Check repository**: `/scripts/restore.sh check`
- **Manual backup**: `/scripts/backup.sh`
- **Manual prune**: `/scripts/prune.sh`

**Restore from backup**:
1. Create a restore directory on your pool: `mkdir -p /mnt/pool/borg-restore`
2. In the TrueNAS web UI, stop the borg-backup app
3. Edit the app and add a **Host Path Volume**:
   - Host Path: `/mnt/pool/borg-restore`
   - Mount Path: `/restore`
4. Save and start the app
5. Access the shell and run: `/scripts/restore.sh extract backup-2026-01-18_12-00-00 /restore`
6. Files will be extracted to `/mnt/pool/borg-restore` on your TrueNAS system

### Docker Compose

#### List Backups

```bash
docker compose run --rm borg-backup /scripts/restore.sh list
```

#### View Archive Information

```bash
docker compose run --rm borg-backup /scripts/restore.sh info backup-2026-01-18_12-00-00
```

#### Restore from Backup

```bash
# Extract to current directory
docker compose run --rm -v $(pwd)/restore:/restore borg-backup \
  /scripts/restore.sh extract backup-2026-01-18_12-00-00 /restore

# Mount archive for browsing
docker compose run --rm -v $(pwd)/mnt:/mnt borg-backup \
  /scripts/restore.sh mount backup-2026-01-18_12-00-00 /mnt
```

#### Check Repository Integrity

```bash
docker compose run --rm borg-backup /scripts/restore.sh check
```

#### Manual Backup

```bash
docker compose run --rm borg-backup /scripts/backup.sh
```

#### Manual Prune

```bash
docker compose run --rm borg-backup /scripts/prune.sh
```

## Docker Compose Example

```yaml
services:
  borg-backup:
    image: diarmuidk/docker-borg-client:latest
    container_name: borg-backup
    environment:
      - BORG_REPO=ssh://user@backup-server.com:22/~/backups
      - BORG_PASSPHRASE=your-strong-passphrase
      - BACKUP_PATHS=/data/photos:/data/documents
      - CRON_SCHEDULE=0 2 * * 0
      - TZ=Europe/London
    volumes:
      - ./ssh:/ssh:ro
      - /mnt/pool/photos:/data/photos:ro
      - /mnt/pool/documents:/data/documents:ro
      - borg-cache:/borg/cache
      - borg-config:/borg/config
    restart: unless-stopped

volumes:
  borg-cache:
  borg-config:
```

## Additional Guides

- **TrueNAS API Key Setup**: [docs/truenas-api-key-setup.md](docs/truenas-api-key-setup.md) - Generate API keys for notifications

## Cron Schedule Examples

The `CRON_SCHEDULE` variable uses standard cron format: `minute hour day-of-month month day-of-week`

| Schedule | Description |
|----------|-------------|
| `0 2 * * 0` | Every Sunday at 2am (default) |
| `0 3 * * *` | Every day at 3am |
| `0 2 * * 1-5` | Weekdays at 2am |
| `0 */6 * * *` | Every 6 hours |
| `30 1 1 * *` | First day of every month at 1:30am |

## Notifications

Docker Borg Client supports sending notifications to TrueNAS SCALE via the TrueNAS WebSocket JSON-RPC API. This allows you to receive alerts through your existing TrueNAS notification channels (email, Slack, etc.).

**Requirements**: TrueNAS SCALE 25.04 or later

### Quick Setup (TrueNAS SCALE)

1. **Generate API Key** in TrueNAS:
   - Navigate to **Settings** → **API Keys**
   - Click **Add** and create a new key
   - Copy the generated key (shown only once!)

2. **Configure Notifications**:
   ```bash
   NOTIFY_TRUENAS_ENABLED=true
   NOTIFY_TRUENAS_API_URL=ws://192.168.1.100  # Your TrueNAS IP with ws:// protocol
   NOTIFY_TRUENAS_API_KEY=1-abc123yourkey
   NOTIFY_EVENTS=backup.failure,backup.success
   ```

   **Note**: Use `ws://` for unencrypted WebSocket connections (recommended for local networks).

3. **Test Notification**:
   ```bash
   # From container shell
   /scripts/notify.sh "backup.success" "INFO" "Test" "This is a test notification"
   ```

For detailed setup instructions, see [TrueNAS API Key Setup Guide](docs/truenas-api-key-setup.md).

### Event Types

- `backup.success` - Backup completed successfully
- `backup.failure` - Backup failed
- `prune.success` - Prune completed successfully
- `prune.failure` - Prune failed
- `container.startup` - Container started (useful for monitoring container health)
- `container.shutdown` - Container stopping (useful for tracking restarts/stops)

**Default**: Only failures are notified (`backup.failure,prune.failure`)

**Tip**: Add `container.startup,container.shutdown` to track container lifecycle events

## Monitoring

View container logs to monitor backup status:

```bash
docker compose logs -f borg-backup
```

## Troubleshooting

### SSH Connection Issues

Test SSH connection manually:
```bash
docker compose run --rm borg-backup ssh -i /ssh/key user@host
```

### Repository Lock

If backup fails due to lock:
```bash
docker compose run --rm borg-backup borg break-lock $BORG_REPO
```

### Storage Space

Check repository size:
```bash
docker compose run --rm borg-backup borg info $BORG_REPO
```

### Verify Backups

Regularly test restores to ensure backups are working:
```bash
docker compose run --rm borg-backup /scripts/restore.sh check
```

## Security Best Practices

1. **Store passphrase securely**: Use a password manager or secrets management system
2. **Backup your passphrase**: Without it, your backups are unrecoverable
3. **Export repository key**: `borg key export $BORG_REPO /path/to/keyfile`
4. **Restrict SSH key**: Use `~/.ssh/authorized_keys` restrictions on the backup server
5. **Use read-only mounts**: Mount source directories as read-only (`:ro`)
6. **Regular integrity checks**: Run `borg check` periodically

### Data Safety

**Your source data is safe**: All backup source directories are mounted **read-only**, so the container cannot modify or delete your original files.

**Potentially destructive operations** (use with caution):
- `borg break-lock` - Only use if you're certain no backup is running
- `borg prune` - Deletes old archives according to retention policy (intended behaviour)
- `borg compact` - Irreversibly frees space by removing deleted data
- Deleting `/borg/cache` or `/borg/config` - Can corrupt repository metadata

**Recommendation**: Test your restore process regularly to ensure backups are working correctly.

## Disaster Recovery

Understanding how Borg encryption works is critical for disaster recovery planning.

### How Borg Encryption Works

Borg uses a two-layer encryption system:

1. **Repository Key**: The actual encryption key that encrypts your data
   - Automatically generated during `borg init`
   - In "repokey" mode (default), stored **inside the repository** on the remote server
   - Encrypted with your passphrase

2. **Passphrase**: The password you set via `BORG_PASSPHRASE`
   - Used to decrypt the repository key
   - Never stored in the repository (you must save it separately)

### What You Need for Recovery

**To restore backups from a new machine, you need:**

| Component | Where it's stored | Critical? |
|-----------|-------------------|-----------|
| Repository access | Remote backup server | ✅ Yes |
| Passphrase | You must save this externally | ✅ Yes |
| Repository key | Inside repo (automatic) | Usually not needed* |

\* The repository key is automatically retrieved from the remote repository when you access it with your passphrase.

**Example recovery scenario** (if your backup client/server fails):

```bash
# On a new machine with Borg installed
borg list ssh://user@backup-server.com:22/path/to/repo
# Enter your passphrase
# Borg downloads the key from repository, decrypts it, shows your backups
```

### When You Need the Exported Key

The exported repository key is **backup insurance** against rare scenarios:

1. **Repository metadata corruption** on the remote server
2. **Faster recovery**: Skip downloading key from repository

The exported key will be stored at `/borg/config/repo-key.txt` (persisted to your host storage).

### Critical Action Items

**⚠️ REQUIRED - Do this during initial setup:**

1. **Save your passphrase** securely (choose one or more):
   - Password manager (1Password, Bitwarden, KeePass, etc.)
   - Printed paper in a safe
   - Encrypted USB drive in secure location
   - **Without the passphrase, your backups are permanently unrecoverable**

2. **Backup the repository key** (automatically exported to `/borg/config/repo-key.txt`):
   ```bash
   # From container shell - view the auto-exported key
   cat /borg/config/repo-key.txt

   # Copy this to your password manager for safekeeping
   ```

3. **Test your recovery** from a different machine to verify your passphrase works

### Recovery Scenarios

| Scenario | What you need | How to recover |
|----------|---------------|----------------|
| **Restore single file** | Repository + passphrase | Use `/scripts/restore.sh extract` |
| **Client system failed** | Repository + passphrase | Install Borg on new machine, access repo with passphrase |
| **Repository corrupted** | Repository + passphrase + **exported key** | `borg key import`, then access repository |
| **Lost passphrase** | ❌ **Backups are permanently lost** | No recovery possible |

### Best Practices

1. ✅ Store passphrase separately from the system being backed up
2. ✅ Export repository key and store securely (separate location)
3. ✅ Test restore process at least once
4. ✅ Keep SSH private key backed up separately
5. ✅ Document your repository URL

**Apply 3-2-1 rule to your encryption credentials:**
- **3** copies (container env var, password manager, printed/offline copy)
- **2** different media types (digital + physical)
- **1** off-site (password manager cloud sync, safe deposit box, etc.)

## Development

### Building

Build locally:
```bash
docker build -t docker-borg-client .
```

Test backup:
```bash
docker run --rm -it \
  -e BORG_REPO=ssh://user@host:22/./backup \
  -e BORG_PASSPHRASE=testpass \
  -e BACKUP_PATHS=/data \
  -v /path/to/data:/data:ro \
  -v ./ssh:/ssh:ro \
  docker-borg-client /scripts/backup.sh
```

### Testing

This project includes comprehensive unit tests for all shell scripts using the [bats-core](https://github.com/bats-core/bats-core) testing framework.

#### Running Tests

Run all tests:
```bash
make test
```

Run a specific test file:
```bash
bats tests/backup.bats
```

#### Installing bats

**macOS:**
```bash
brew install bats-core
```

**Ubuntu/Debian:**
```bash
sudo apt-get install bats
```

**Other systems:**
```bash
git clone https://github.com/bats-core/bats-core.git
cd bats-core
./install.sh /usr/local
```

#### Test Coverage

The test suite covers all shell scripts in the `/scripts` directory:
- `auto-release.bats` - Tests container startup behavior
- `backup.bats` - Tests backup execution and rate limiting
- `check-window.bats` - Tests backup window time checking
- `init.bats` - Tests repository initialization
- `notify.bats` - Tests notification system
- `prune.bats` - Tests archive pruning logic
- `restore.bats` - Tests restore operations
- `window-monitor.bats` - Tests window monitoring and backup termination

Tests run automatically on every push and pull request via GitHub Actions.

## Contributing

Contributions welcome! Please open an issue or pull request.

## Licence

See [LICENCE](LICENCE) file for details.

## Acknowledgements

This project uses [BorgBackup](https://www.borgbackup.org/), an excellent deduplicating backup program.
