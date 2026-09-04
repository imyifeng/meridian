# Meridian build helper.
#
# The Web 管理控制台 and the Web 简易客户端 (Flutter Web) are embedded into
# the meridian binary at compile time (internal/webconsole, internal/webclient),
# so `make build` runs the Flutter builds first. `go build` alone on a fresh
# checkout still works: dist/ then holds only a placeholder and /console/ and
# /web/ explain how to build.

FLUTTER ?= flutter

.PHONY: web-console web-client build test

# Builds the console SPA into internal/webconsole/dist (gitignored build
# output) with the base href the server mounts it under.
web-console:
	cd client && $(FLUTTER) build web --target lib/console_main.dart --base-href=/console/
	find internal/webconsole/dist -mindepth 1 ! -name '.gitignore' -delete
	cp -r client/build/web/. internal/webconsole/dist/

# Builds the Web 简易客户端 SPA into internal/webclient/dist the same way.
web-client:
	cd client && $(FLUTTER) build web --target lib/web_main.dart --base-href=/web/
	find internal/webclient/dist -mindepth 1 ! -name '.gitignore' -delete
	cp -r client/build/web/. internal/webclient/dist/

build: web-console web-client
	go build -o build/meridian ./cmd/meridian

test:
	go test ./...
	cd client && $(FLUTTER) test
