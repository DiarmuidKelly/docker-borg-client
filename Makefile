.PHONY: test test-alpine build

test:
	@bats tests/*.bats

test-alpine:
	@docker run --rm -v "$(PWD):/workspace" -w /workspace alpine:3 sh -c '\
		apk add --no-cache bash bats coreutils git && \
		bats tests/*.bats'

build:
	docker build -t docker-borg-client .