# TrueNAS API Key Setup Guide

This guide explains how to generate an API key for TrueNAS SCALE to enable notifications from the Docker Borg Client.

## Prerequisites

- TrueNAS SCALE installed and accessible
- Admin access to the TrueNAS web interface

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
NOTIFY_TRUENAS_API_URL=http://192.168.1.100/api/v2.0  # Replace with your TrueNAS IP
NOTIFY_TRUENAS_API_KEY=1-abc123yourapikey              # Your actual API key
NOTIFY_TRUENAS_VERIFY_SSL=false                        # For self-signed certs
NOTIFY_EVENTS=backup.failure,backup.success
```

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

## HTTP vs HTTPS

### Using HTTP (Recommended for Internal Networks)

```bash
NOTIFY_TRUENAS_API_URL=http://192.168.1.100/api/v2.0
```

**Pros**:
- Simpler setup
- No certificate issues
- Secure for internal/home networks

**Use when**: TrueNAS is on your local network

### Using HTTPS with Self-Signed Certificate

```bash
NOTIFY_TRUENAS_API_URL=https://192.168.1.100/api/v2.0
NOTIFY_TRUENAS_VERIFY_SSL=false  # Required for self-signed certs
```

**Pros**:
- Encrypted communication
- Better for enterprise environments

**Use when**:
- Corporate environment requires HTTPS
- Accessing TrueNAS remotely
- You have a valid SSL certificate

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

### "Notification failed (HTTP 401)"

**Problem**: Invalid API key

**Solution**:
- Verify you copied the entire API key correctly
- Generate a new API key if needed
- Ensure no extra spaces or quotes in the key

### "Notification failed (HTTP 404)"

**Problem**: Incorrect API URL

**Solution**:
- Verify the URL format: `http://IP/api/v2.0`
- Check your TrueNAS IP address
- Ensure `/api/v2.0` is included in the URL

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
3. **Use HTTP for Local Networks**: HTTPS overhead not needed for internal networks
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
