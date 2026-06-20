#!/bin/bash
# Runs the E2E test suite. All test logic lives in client-test.sh inside the container.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE="docker compose -f ${REPO_ROOT}/docker-compose.e2e.yml"

cleanup() {
    echo
    echo "==> Tearing down"
    ${COMPOSE} down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Building images"
${COMPOSE} build --quiet

echo "==> Running E2E tests"
${COMPOSE} up --abort-on-container-exit --exit-code-from borg-client
