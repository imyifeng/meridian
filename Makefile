# Meridian build helper.
#
# The Web 管理控制台 and the Web 简易客户端 (Flutter Web) are embedded into
# the meridian binary at compile time (internal/webconsole, internal/webclient),
# so `make build` runs the Flutter builds first. `go build` alone on a fresh
# checkout still works: dist/ then holds only a placeholder and /console/ and
# /web/ explain how to build.

FLUTTER ?= flutter

.PHONY: web-console web-client build test

# Builds one frontend SPA into its embedded dist/ with the base href the
# server mounts it under: $(1) lib entry, $(2) base href, $(3) dist dir.
define flutter-web
cd client && $(FLUTTER) build web --target $(1) --base-href=$(2)
find $(3) -mindepth 1 ! -name '.gitignore' -delete
cp -r client/build/web/. $(3)/
endef

web-console:
	$(call flutter-web,lib/console_main.dart,/console/,internal/webconsole/dist)

# Builds the Web 简易客户端 SPA the same way.
web-client:
	$(call flutter-web,lib/web_main.dart,/web/,internal/webclient/dist)

build: web-console web-client
	go build -o build/meridian ./cmd/meridian

test:
	go test ./...
	cd client && $(FLUTTER) test
