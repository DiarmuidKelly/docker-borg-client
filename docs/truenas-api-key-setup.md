# TrueNAS API Key Setup Guide

This guide explains how to generate an API key for TrueNAS SCALE to enable notifications from the Docker Borg Client.

## Prerequisites

- TrueNAS SCALE 25.04 or later (uses WebSocket JSON-RPC API)
- Admin access to the TrueNAS web interface

**Note**: TrueNAS SCALE 25.04+ uses WebSocket JSON-RPC for API communication. The old REST API has been deprecated and will be removed in 26.04.

## Generate API Key

### Step 1: Access API Keys Settings

1. Log in to your TrueNAS SCALE web interface
2. Navigate to the top-right corner and click your **username**
3. Select **API Keys** from the dropdown menu

   Alternatively, you can navigate directly to: **Settings** → **API Keys**

### Step 2: Create New API Key

1. Click **Add** (or **+ Add API Key**)
2. Configure the API key:
   - **Name**: `borg-backup-notifications` (or any descriptive name)
   - **Description** (optional): "API key for Borg backup notifications"
   - **Allow List** (optional): Leave empty or add the container IP range for extra security
3. Click **Save**

### Step 3: Copy the API Key

**IMPORTANT**: The API key will only be displayed **once**. Make sure to copy it immediately!

1. After clicking Save, a dialog will appear with your API key
2. Copy the entire key (format: `1-abc123...`)
3. Store it securely (password manager recommended)

If you lose the key, you'll need to generate a new one.

### Step 4: Configure Docker Borg Client

Add the API key to your `.env` file or Docker Compose environment variables:

```bash
NOTIFY_TRUENAS_ENABLED=true
NOTIFY_TRUENAS_API_URL=ws://192.168.1.100  # Replace with your TrueNAS IP
NOTIFY_TRUENAS_API_KEY=1-abc123yourapikey  # Your actual API key
NOTIFY_EVENTS=backup.failure,backup.success
```

**Important**: Use `ws://` for WebSocket connections (recommended for local networks).

## Finding Your TrueNAS IP Address

If you don't know your TrueNAS IP address:

1. **Via Web Interface**:
   - Navigate to **Network** → **Interfaces**
   - Look for your active network interface (usually `enp0s3` or `eth0`)
   - Note the **IP Address** shown

2. **Via Shell**:
   ```bash
   hostname -I
   ```

3. **From Another Computer**:
   ```bash
   # The IP you use to access TrueNAS web UI
   # Example: http://192.168.1.100
   ```

## WebSocket Protocol

### Using ws:// (Recommended for Internal Networks)

```bash
NOTIFY_TRUENAS_API_URL=ws://192.168.1.100
```

**Use when**: TrueNAS is on your local/home network (most common)

**Why unencrypted is fine**: WebSocket traffic stays within your local network and doesn't traverse the internet. The API key provides authentication.

### Using wss:// (Encrypted WebSocket)

Only needed if you have proper SSL certificates configured on TrueNAS:

```bash
NOTIFY_TRUENAS_API_URL=wss://truenas.local
NOTIFY_TRUENAS_VERIFY_SSL=false  # Only if using self-signed certificates
```

**Use when**: Corporate environment requires encrypted traffic or accessing TrueNAS remotely.

## Testing the Configuration

### Method 1: Manual Test via Container Shell

1. Access your borg-backup container shell (TrueNAS web UI):
   - **Apps** → **Installed** → **borg-backup** → **Shell**

2. Run a test notification:
   ```bash
   /scripts/notify.sh "backup.success" "INFO" \
       "Test Notification" \
       "This is a test message from Borg Backup"
   ```

3. Check TrueNAS alerts:
   - Top-right **bell icon** in TrueNAS web UI
   - You should see your test notification

### Method 2: Run a Manual Backup

```bash
# In container shell
/scripts/backup.sh
```

If configured correctly, you'll receive a notification when the backup completes.

## Troubleshooting

### "Notification failed: Unauthorized" or Authentication Errors

**Problem**: Invalid API key

**Solution**:
- Verify you copied the entire API key correctly
- Generate a new API key if needed
- Ensure no extra spaces or quotes in the key
- For HTTPS (wss://), ensure SSL verification matches your cert setup

### "Notification failed: Connection refused" or "Failed to connect"

**Problem**: Cannot reach TrueNAS WebSocket endpoint

**Solution**:
- Verify the URL format: `ws://IP` (use WebSocket protocol)
- Check your TrueNAS IP address is correct
- Ensure TrueNAS is accessible from the container network
- Test connectivity: `ping 192.168.1.100` from container

### "Could not resolve host"

**Problem**: Container cannot reach TrueNAS

**Solution**:
- Use TrueNAS **IP address**, not `localhost`
- Verify the IP address is correct
- Check container networking

### "SSL certificate problem"

**Problem**: Self-signed certificate with SSL verification enabled

**Solution**:
- Set `NOTIFY_TRUENAS_VERIFY_SSL=false`
- Or use HTTP instead of HTTPS

### No Notifications Received

**Checklist**:
1. Is `NOTIFY_TRUENAS_ENABLED=true`?
2. Is the event in your `NOTIFY_EVENTS` list?
3. Check container logs for error messages
4. Verify TrueNAS alert settings (Settings → Alert Settings)

## Security Best Practices

1. **Store API Key Securely**: Use environment variables, never commit to git
2. **Limit API Key Scope**: Use a dedicated API key for Borg backup only
3. **Use ws:// for Local Networks**: Unencrypted WebSocket is fine for internal networks
4. **Rotate Keys Periodically**: Generate new API keys every 6-12 months
5. **Monitor API Key Usage**: Check TrueNAS audit logs regularly

## Revoking an API Key

If your API key is compromised:

1. Navigate to **Settings** → **API Keys**
2. Find the compromised key in the list
3. Click the **Delete** button
4. Generate a new API key
5. Update your Docker Borg Client configuration

## Additional Resources

- [TrueNAS SCALE API Documentation](https://www.truenas.com/docs/scale/scaletutorials/apikeys/)
- [TrueNAS SCALE Alert Settings](https://www.truenas.com/docs/scale/scaleuireference/systemsettings/alertsettingssscale/)
