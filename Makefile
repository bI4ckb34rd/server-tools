SHELL := /usr/bin/env bash

.PHONY: build lint fmt test test-netns clean

build:
	bash build.sh

lint: build
	shellcheck -x dist/server-tools.sh build.sh tests/*.sh
	shfmt -i 2 -ci -d src build.sh tests

fmt:
	shfmt -i 2 -ci -w src build.sh tests

test:
	bash tests/smoke.sh
	bash tests/unit.sh

# Needs root: real kernel, isolated in a private network/mount namespace.
test-netns: build
	sudo bash tests/netns.sh

clean:
	rm -f dist/server-tools.sh
