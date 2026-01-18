#!/bin/sh
set -e

echo "========================================="
echo "Initializing Borg Repository"
echo "========================================="
echo "Repository: $BORG_REPO"
echo ""

# Initialize repository with repokey encryption
borg init --encryption=repokey "$BORG_REPO"

echo ""
echo "✅ Repository initialized successfully!"
echo ""

# Automatically export repository key
echo "Exporting repository key to /borg/config/repo-key.txt..."
borg key export "$BORG_REPO" /borg/config/repo-key.txt

echo ""
echo "========================================="
echo "⚠️  CRITICAL: BACKUP THESE CREDENTIALS"
echo "========================================="
echo ""
echo "1. Passphrase (from BORG_PASSPHRASE env var)"
echo "   → Save to password manager NOW"
echo ""
echo "2. Repository Key: /borg/config/repo-key.txt"
echo "   → View: cat /borg/config/repo-key.txt"
echo "   → Copy to password manager for disaster recovery"
echo ""
echo "Without BOTH of these, your backups may be unrecoverable!"
echo "========================================="
