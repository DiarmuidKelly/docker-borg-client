# Notifications Feature

> **Update (2026-01)**: This feature was implemented using TrueNAS WebSocket JSON-RPC API instead of REST API. TrueNAS SCALE 25.04+ deprecated the REST API in favour of WebSocket JSON-RPC. See the implementation in `scripts/notify.sh` which uses `websocat` for WebSocket communication.

## Overview

Add notification support to Docker Borg Client to alert users about backup success/failure and other important events. This is particularly useful for TrueNAS SCALE users who want to monitor automated backups.

## Goals

1. Notify on backup success/failure with statistics
2. Notify on critical errors (SSH connection failures, repository corruption, etc.)
3. Native TrueNAS SCALE integration via API
4. Simple configuration via environment variables
5. Optional - don't break existing setups

## Notification Backend

### TrueNAS API
**Use case**: Native TrueNAS SCALE alerts

- Send alerts directly to TrueNAS notification system
- Requires TrueNAS API key
- Integrates with existing TrueNAS alert configuration (email, Slack, etc.)

**Environment Variables**:
```bash
NOTIFY_TRUENAS_ENABLED=true
NOTIFY_TRUENAS_API_URL=http://192.168.1.100/api/v2.0  # Replace with your TrueNAS IP
NOTIFY_TRUENAS_API_KEY=your-api-key
NOTIFY_TRUENAS_VERIFY_SSL=false  # Set to false for self-signed certificates (default: true)
```

**Important Notes**:
- Use the **IP address** of your TrueNAS host (not `localhost` - containers cannot access host's localhost)
- For **HTTPS with self-signed certificates**, set `VERIFY_SSL=false`
- For **HTTP** (recommended for internal networks), no SSL verification needed
- The API endpoint is the same as the web UI: `http(s)://truenas-ip/api/v2.0`

**Implementation**:
```bash
# Build curl command with optional SSL verification flag
CURL_OPTS=""
[ "$NOTIFY_TRUENAS_VERIFY_SSL" = "false" ] && CURL_OPTS="-k"

curl $CURL_OPTS -X POST "$NOTIFY_TRUENAS_API_URL/alert/oneshot/create" \
  -H "Authorization: Bearer $NOTIFY_TRUENAS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "klass": "CustomAlert",
    "args": {
      "title": "Borg Backup Status",
      "message": "Backup completed successfully. Size: 1.2GB, Duration: 5m",
      "level": "INFO"
    }
  }'
```

**Alert Levels**:
- `INFO` - Successful backups
- `WARNING` - Backup succeeded but with warnings
- `CRITICAL` - Backup failed

## Notification Events

### Event Types

1. **Backup Success** (`backup.success`)
   - Level: INFO
   - Includes: Duration, size, archive name, compression ratio

2. **Backup Failure** (`backup.failure`)
   - Level: CRITICAL
   - Includes: Error message, exit code, timestamp

3. **Prune Success** (`prune.success`)
   - Level: INFO
   - Includes: Archives deleted, space freed

4. **Prune Failure** (`prune.failure`)
   - Level: CRITICAL
   - Includes: Error message

5. **Repository Check Warning** (`check.warning`)
   - Level: WARNING
   - Includes: Warning details

6. **Repository Check Failure** (`check.failure`)
   - Level: CRITICAL
   - Includes: Error details

7. **SSH Connection Failure** (`ssh.failure`)
   - Level: CRITICAL
   - Includes: Host, error message

### Event Filtering

Allow users to choose which events to notify:

```bash
NOTIFY_EVENTS=backup.failure,backup.success,check.failure
# Default: backup.failure,check.failure (only failures)
```

## Implementation Plan

### Phase 1: Core Infrastructure
1. Create `scripts/notify.sh` - notification dispatcher
2. Add TrueNAS API notification helper
3. Update `backup.sh` to call notification on success/failure
4. Update `prune.sh` to call notification on completion

### Phase 2: TrueNAS Integration
1. Implement TrueNAS API notification
2. Add instructions for generating API key
3. Test with TrueNAS SCALE

### Phase 3: Documentation
1. Update README with notification configuration
2. Add TrueNAS-specific guide for API key generation
3. Update .env.example with notification variables

## Script Structure

### `scripts/notify.sh`

```bash
#!/bin/sh
# Notification dispatcher

EVENT_TYPE="$1"      # e.g., backup.success, backup.failure
EVENT_LEVEL="$2"     # INFO, WARNING, CRITICAL
EVENT_TITLE="$3"     # Short title
EVENT_MESSAGE="$4"   # Detailed message

# Check if this event should be notified
if ! should_notify "$EVENT_TYPE"; then
    exit 0
fi

# Send to TrueNAS if enabled
[ "$NOTIFY_TRUENAS_ENABLED" = "true" ] && notify_truenas
```

### Updated `scripts/backup.sh`

```bash
#!/bin/sh
set -e

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
START_TIME=$(date +%s)

# Run backup
if borg create ... ; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    # Get backup statistics
    ARCHIVE_SIZE=$(borg info --last 1 --json | jq -r '.archives[0].stats.original_size')

    /scripts/notify.sh "backup.success" "INFO" \
        "Backup Successful" \
        "Backup completed in ${DURATION}s. Size: ${ARCHIVE_SIZE}"
else
    /scripts/notify.sh "backup.failure" "CRITICAL" \
        "Backup Failed" \
        "Backup failed at $(date). Exit code: $?"
    exit 1
fi
```

## Configuration Example

### TrueNAS SCALE with API Notifications (HTTP)

```yaml
environment:
  # Existing settings
  - BORG_REPO=ssh://...
  - BORG_PASSPHRASE=...

  # Notification settings (HTTP - recommended for internal networks)
  - NOTIFY_TRUENAS_ENABLED=true
  - NOTIFY_TRUENAS_API_URL=http://192.168.1.100/api/v2.0  # Replace with your TrueNAS IP
  - NOTIFY_TRUENAS_API_KEY=1-abc123...
  - NOTIFY_EVENTS=backup.failure,backup.success
```

### TrueNAS SCALE with HTTPS and Self-Signed Certificate

```yaml
environment:
  # Notification settings (HTTPS with self-signed cert)
  - NOTIFY_TRUENAS_ENABLED=true
  - NOTIFY_TRUENAS_API_URL=https://192.168.1.100/api/v2.0  # Replace with your TrueNAS IP
  - NOTIFY_TRUENAS_API_KEY=1-abc123...
  - NOTIFY_TRUENAS_VERIFY_SSL=false  # Required for self-signed certificates
  - NOTIFY_EVENTS=backup.failure,backup.success
```

### Docker Compose (Non-TrueNAS)

For non-TrueNAS users, notifications can be disabled or configured to send to a remote TrueNAS instance if desired:

```yaml
environment:
  # Optional: Send to remote TrueNAS instance
  - NOTIFY_TRUENAS_ENABLED=true
  - NOTIFY_TRUENAS_API_URL=https://truenas-host/api/v2.0
  - NOTIFY_TRUENAS_API_KEY=1-abc123...
  - NOTIFY_EVENTS=backup.failure,backup.success
```

## Testing Plan

1. Test TrueNAS API notifications with valid/invalid API keys
2. Test different alert levels (INFO, WARNING, CRITICAL)
3. Test failure scenarios (network down, invalid URLs, invalid API key)
4. Test event filtering
5. Verify backward compatibility (no notifications when not configured)
6. Test notification failures don't break backups

## Security Considerations

1. **API Keys**: Store in environment variables, never in code
2. **Network Access**:
   - Use HTTP for internal/home networks (simple, secure for private networks)
   - Use HTTPS for remote access or enterprise environments
   - Self-signed certificates are common with TrueNAS - use `VERIFY_SSL=false` if needed
3. **Container Networking**: Container must access TrueNAS via **IP address**, not localhost
4. **Error Handling**: Don't expose sensitive data in error messages
5. **Permissions**: Notification failures should not break backups
6. **API Key Scope**: Use TrueNAS API keys with minimal required permissions

## Backward Compatibility

- All notification features are **opt-in**
- Existing setups continue to work without any configuration changes
- No breaking changes to existing scripts or environment variables

## Future Enhancements (Out of Scope for v1)

1. Additional notification backends (ntfy.sh, webhooks, email)
2. Notification templates (customisable message format)
3. Retry logic for failed notifications
4. Notification aggregation (daily summary)
5. Integration with monitoring systems (Prometheus, Grafana)
