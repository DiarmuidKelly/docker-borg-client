.PHONY: test test-alpine test-e2e build

# Run unit tests locally (requires bats-core: brew/apt install bats)
test:
	@bats tests/*.bats

# Run unit tests inside an Alpine container (mirrors CI environment)
test-alpine:
	@docker run --rm -v "$(PWD):/workspace" -w /workspace alpine:3 sh -c '\
		apk add --no-cache bash bats coreutils git && \
		bats tests/*.bats'

# Run full E2E tests: real borg-server + client, backup → verify → restore
# Uses docker-compose.e2e.yml; requires Docker and Docker Compose v2
test-e2e:
	@bash tests/e2e/run.sh

build:
	docker build -t docker-borg-client .
