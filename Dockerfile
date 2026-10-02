FROM alpine:3

# Pinned to the version in the Alpine community repository. Upstream Borg
# stable is 1.4.5, but Alpine 3.24 community only packages 1.4.4-r1 - bump this
# pin once a newer -rN appears (check: apk policy borgbackup).
ARG BORG_VERSION=1.4.4-r1

# Install Borg, SSH client, curl for notifications, jq for JSON parsing, websocat for WebSocket API calls, then create directories
# borgbackup-fuse provides the pyfuse3 bindings `borg mount` needs - without it
# mount fails with "no FUSE support", which breaks the browse-the-archive
# recovery path. Mounting also needs --device /dev/fuse --cap-add SYS_ADMIN.
# hadolint ignore=DL3018
RUN apk add --no-cache \
    borgbackup=${BORG_VERSION} \
    borgbackup-fuse=${BORG_VERSION} \
    openssh-client \
    curl \
    jq \
    websocat \
    tzdata && \
    mkdir -p /data /ssh /borg/cache /borg/config /scripts /restore

# Copy scripts
COPY scripts/*.sh /scripts/
COPY entrypoint.sh /entrypoint.sh

# Baked in so the container can report its own version and licence on start
COPY VERSION /VERSION
COPY LICENCE /LICENCE

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
