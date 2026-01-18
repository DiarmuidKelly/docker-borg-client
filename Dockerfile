FROM alpine:3

# Install Borg, SSH client, and curl for notifications, then create directories
# hadolint ignore=DL3018
RUN apk add --no-cache \
    borgbackup \
    openssh-client \
    curl \
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

ENTRYPOINT ["/entrypoint.sh"]
