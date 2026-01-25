.PHONY: test build

test:
	@bats tests/*.bats

build:
	docker build -t docker-borg-client .