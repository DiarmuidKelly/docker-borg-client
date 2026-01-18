# Borg Backup Docker Container

## Project Overview

A minimal, generic Docker container for running Borg backups to any remote SSH-accessible Borg repository. Designed for TrueNAS but works anywhere Docker runs.

## Design Principles

- Minimal: Alpine Linux + Borg + SSH client only
- Generic: Works with any Borg-over-SSH target
- Transparent: No abstractions over Borg commands
- Configurable: Environment variables for all settings
- Secure: Client-side encryption, SSH key authentication

## Repository Structure
```
docker-borg-client/
├── Dockerfile
├── entrypoint.sh
├── docker-compose.yml
├── .env.example
├── README.md
├── VERSION
├── .github/
│   └── workflows/
│       ├── build-and-push.yml
│       ├── pr-release.yml
│       └── pr-validation.yml
├── docs/
│   ├── setup-hetzner.md
│   ├── setup-rsync-net.md
│   └── setup-self-hosted.md
└── scripts/
    ├── auto-release.sh
    ├── backup.sh
    ├── prune.sh
    ├── restore.sh
    └── init.sh
```

## Container Specification

**Base image**: `alpine:latest`

**Installed packages**:
- `borgbackup`
- `openssh-client`

**Environment variables**:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BORG_REPO` | Yes | - | Full SSH URL to repository |
| `BORG_PASSPHRASE` | Yes | - | Repository encryption passphrase |
| `BACKUP_PATHS` | Yes | - | Colon-separated paths to back up |
| `BORG_RSH` | No | `ssh -i /ssh/key -o StrictHostKeyChecking=accept-new` | SSH command |
| `PRUNE_KEEP_DAILY` | No | `7` | Daily archives to keep |
| `PRUNE_KEEP_WEEKLY` | No | `4` | Weekly archives to keep |
| `PRUNE_KEEP_MONTHLY` | No | `6` | Monthly archives to keep |
| `CRON_SCHEDULE` | No | `0 2 * * 0` | Cron expression (default: Sunday 2am) |
| `RUN_ON_START` | No | `false` | Run backup immediately on container start |

**Volume mounts**:

| Container path | Purpose | Mode |
|----------------|---------|------|
| `/data` | Source directories to back up | read-only |
| `/ssh` | SSH private key | read-only |
| `/borg/cache` | Borg cache (improves performance) | read-write |
| `/borg/config` | Borg config persistence | read-write |

## Scripts Specification

**entrypoint.sh**:
- Validates required environment variables
- Sets up cron job from `CRON_SCHEDULE`
- Optionally runs backup on start if `RUN_ON_START=true`
- Starts cron daemon in foreground

**scripts/init.sh**:
- Runs `borg init --encryption=repokey`
- Called manually once during setup

**scripts/backup.sh**:
- Runs `borg create` with timestamp-based archive name
- Backs up all paths in `BACKUP_PATHS`
- Logs output

**scripts/prune.sh**:
- Runs `borg prune` with configured retention
- Runs `borg compact`

**scripts/restore.sh**:
- Helper for listing and extracting archives
- Usage documented in README

## Docker Compose Example
```yaml
services:
  borg-backup:
    build: .
    container_name: borg-backup
    environment:
      - BORG_REPO=${BORG_REPO}
      - BORG_PASSPHRASE=${BORG_PASSPHRASE}
      - BACKUP_PATHS=/data/photos:/data/documents
      - CRON_SCHEDULE=0 2 * * 0
    volumes:
      - /mnt/pool/photos:/data/photos:ro
      - /mnt/pool/documents:/data/documents:ro
      - ./ssh:/ssh:ro
      - borg-cache:/borg/cache
      - borg-config:/borg/config
    restart: unless-stopped

volumes:
  borg-cache:
  borg-config:
```

## README Sections

1. Overview
2. Quick start
3. Configuration reference
4. Initial setup (generating keys, init repo)
5. Manual operations (list, restore, check)
6. Provider-specific guides (links to docs/)
7. Monitoring and healthchecks (future)
8. Troubleshooting

## Future Enhancements (out of scope for v1)

- Healthcheck endpoint
- Webhook notifications on success/failure
- Multiple repository support
- Pre/post backup hooks

## Build and Test Commands
```bash
# Build
docker build -t docker-borg-client .

# Test init
docker run --rm -it \
  -e BORG_REPO=ssh://user@host:22/./backup \
  -e BORG_PASSPHRASE=testpass \
  -v ./ssh:/ssh:ro \
  docker-borg-client /scripts/init.sh

# Test backup manually
docker run --rm -it \
  -e BORG_REPO=ssh://user@host:22/./backup \
  -e BORG_PASSPHRASE=testpass \
  -e BACKUP_PATHS=/data \
  -v /path/to/data:/data:ro \
  -v ./ssh:/ssh:ro \
  docker-borg-client /scripts/backup.sh
```
