# Docker Borg Client

A minimal, generic Docker container for running [BorgBackup](https://www.borgbackup.org/) backups to any remote SSH-accessible Borg repository. Designed for TrueNAS but works anywhere Docker runs.

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

1. **Create Borg User and Group** (recommended for security):
   - SSH into your TrueNAS SCALE system or use the Shell in the web UI
   - Create a dedicated user and group for Borg backups:
     ```bash
     # Create borg group (GID 568 - standard for TrueNAS custom apps)
     groupadd -g 568 borg

     # Create borg user (UID 568)
     useradd -u 568 -g 568 -d /nonexistent -s /usr/sbin/nologin borg
     ```

2. **Prepare SSH Keys**:
   - Create a directory for your SSH keys with proper ownership:
     ```bash
     mkdir -p /mnt/pool/borg-backup/ssh
     ssh-keygen -t ed25519 -f /mnt/pool/borg-backup/ssh/key -N ""
     chown -R 568:568 /mnt/pool/borg-backup/ssh
     chmod 700 /mnt/pool/borg-backup/ssh
     chmod 600 /mnt/pool/borg-backup/ssh/key
     ```
   - Add the public key to your remote backup server:
     ```bash
     cat /mnt/pool/borg-backup/ssh/key.pub
     ```

3. **Deploy Custom App**:
   - Navigate to **Apps** → **Discover Apps** → **Custom App**
   - Click **Install** on Custom App
   - Configure the following:

   **Application Name**: `borg-backup`

   **Image Configuration**:
   - Image Repository: `ghcr.io/diarmuidkelly/docker-borg-client`
   - Image Tag: `latest`
   - Image Pull Policy: `Always`

   **Container User and Group** (under Advanced Settings):
   - User ID: `568`
   - Group ID: `568`

   **Environment Variables** (Add all of these):
   ```
   BORG_REPO=ssh://user@your-backup-server.com:22/~/backups
   BORG_PASSPHRASE=your-strong-passphrase-here
   BACKUP_PATHS=/data/dataset1:/data/dataset2
   CRON_SCHEDULE=0 2 * * 0
   PRUNE_KEEP_DAILY=7
   PRUNE_KEEP_WEEKLY=4
   PRUNE_KEEP_MONTHLY=6
   TZ=Europe/London
   ```

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

4. **Initialize Repository** (one-time):
   - After deployment, access the container shell via TrueNAS web UI
   - Navigate to **Apps** → **Installed** → **borg-backup** → **Shell**
   - Run: `/scripts/init.sh`
   - Save the passphrase and export the repository key

4. **Monitor Backups**:
   - View logs: **Apps** → **Installed** → **borg-backup** → **Logs**
   - Backups will run automatically according to your cron schedule

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
| `PRUNE_KEEP_DAILY` | No | `7` | Daily archives to keep |
| `PRUNE_KEEP_WEEKLY` | No | `4` | Weekly archives to keep |
| `PRUNE_KEEP_MONTHLY` | No | `6` | Monthly archives to keep |
| `TZ` | No | `UTC` | Timezone for cron jobs |

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
    image: ghcr.io/diarmuidkelly/docker-borg-client:latest
    container_name: borg-backup
    environment:
      - BORG_REPO=ssh://u123456@u123456.your-storagebox.de:23/./backups
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

## Provider-Specific Guides

- **Hetzner Storage Box**: See [docs/setup-hetzner.md](docs/setup-hetzner.md) (coming soon)
- **rsync.net**: See [docs/setup-rsync-net.md](docs/setup-rsync-net.md) (coming soon)
- **Self-hosted**: See [docs/setup-self-hosted.md](docs/setup-self-hosted.md) (coming soon)

## Cron Schedule Examples

The `CRON_SCHEDULE` variable uses standard cron format: `minute hour day-of-month month day-of-week`

| Schedule | Description |
|----------|-------------|
| `0 2 * * 0` | Every Sunday at 2am (default) |
| `0 3 * * *` | Every day at 3am |
| `0 2 * * 1-5` | Weekdays at 2am |
| `0 */6 * * *` | Every 6 hours |
| `30 1 1 * *` | First day of every month at 1:30am |

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
7. **Run as non-root user**: Use UID/GID 568 (or another non-root user) to limit container privileges

### Data Safety

**Your source data is safe**: All backup source directories are mounted **read-only**, so the container cannot modify or delete your original files.

**Potentially destructive operations** (use with caution):
- `borg break-lock` - Only use if you're certain no backup is running
- `borg prune` - Deletes old archives according to retention policy (intended behaviour)
- `borg compact` - Irreversibly frees space by removing deleted data
- Deleting `/borg/cache` or `/borg/config` - Can corrupt repository metadata

**Recommendation**: Test your restore process regularly to ensure backups are working correctly.

## Development

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

## Contributing

Contributions welcome! Please open an issue or pull request.

## Licence

See [LICENCE](LICENCE) file for details.

## Acknowledgements

This project uses [BorgBackup](https://www.borgbackup.org/), an excellent deduplicating backup program.
