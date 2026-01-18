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
echo "IMPORTANT: Save your passphrase securely!"
echo "Passphrase: $BORG_PASSPHRASE"
echo ""
echo "Also export and save the repository key:"
echo "  borg key export $BORG_REPO /path/to/keyfile"
echo "========================================="
