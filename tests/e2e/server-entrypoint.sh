#!/bin/sh
set -e

# Generate SSH host keys on first start
ssh-keygen -A

# Install authorised key from mounted file (written by test runner)
if [ -f /tmp/authorized_keys ]; then
    cp /tmp/authorized_keys /home/borguser/.ssh/authorized_keys
    chmod 600 /home/borguser/.ssh/authorized_keys
    chown borguser:borguser /home/borguser/.ssh/authorized_keys
fi

exec /usr/sbin/sshd -D -e
