FROM alpine:3

# Install Borg, SSH client, curl for notifications, jq for JSON parsing, then create directories
# hadolint ignore=DL3018
RUN apk add --no-cache \
    borgbackup \
    openssh-client \
    curl \
    jq \
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
ENV BORG_RSH="ssh -i /ssh/key -o StrictHostKeyChecking=accept-new"

ENTRYPOINT ["/entrypoint.sh"]
