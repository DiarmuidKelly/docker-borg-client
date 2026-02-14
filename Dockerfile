FROM alpine:3

# Install Borg, SSH client, curl for notifications, jq for JSON parsing, websocat for WebSocket API calls, then create directories
# hadolint ignore=DL3018
RUN apk add --no-cache \
    borgbackup \
    openssh-client \
    curl \
    jq \
    websocat \
    tzdata && \
    mkdir -p /data /ssh /borg/cache /borg/config /scripts

# Copy scripts
COPY scripts/*.sh /scripts/
COPY entrypoint.sh /entrypoint.sh

# Make scripts executable
RUN chmod +x /entrypoint.sh /scripts/*.sh

# Set Borg cache and config directories
ENV BORG_CACHE_DIR=/borg/cache
ENV BORG_CONFIG_DIR=/borg/config

# Use modern exit codes for more specific error reporting
ENV BORG_EXIT_CODES=modern

# Set default SSH command for Borg (can be overridden via environment variable)
# Includes keepalive and retry options for connection resilience
ENV BORG_RSH="ssh -i /ssh/key -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ConnectionAttempts=3"

ENTRYPOINT ["/entrypoint.sh"]
