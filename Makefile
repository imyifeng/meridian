# Meridian build helper.
#
# The Web 管理控制台 (Flutter Web) is embedded into the meridian binary at
# compile time (internal/webconsole), so `make build` runs the Flutter build
# first. `go build` alone on a fresh checkout still works: dist/ then holds
# only a placeholder and /console/ explains how to build.

FLUTTER ?= flutter

.PHONY: web-console build test

# Builds the console SPA into internal/webconsole/dist (gitignored build
# output) with the base href the server mounts it under.
web-console:
	cd client && $(FLUTTER) build web --target lib/console_main.dart --base-href=/console/
	find internal/webconsole/dist -mindepth 1 ! -name '.gitignore' -delete
	cp -r client/build/web/. internal/webconsole/dist/

build: web-console
	go build -o build/meridian ./cmd/meridian

test:
	go test ./...
	cd client && $(FLUTTER) test
