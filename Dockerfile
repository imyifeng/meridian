# Meridian trial deployment image (T11): `docker compose up -d --build`
# builds everything from source — the two Flutter Web SPAs the binary
# embeds, then the static Go server — and the resulting image runs the
# instance with its data on a volume.

# --- Web: build the 管理控制台 and 简易客户端 SPAs with the exact Flutter
# stable release the repo is developed against (client/pubspec.lock pins
# packages; the release tarball pins the SDK). ---
FROM debian:bookworm-slim AS web
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/flutter.tar.xz \
      https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.2-stable.tar.xz \
 && tar -xJf /tmp/flutter.tar.xz --no-same-owner -C /opt \
 && rm /tmp/flutter.tar.xz
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics && flutter --version

WORKDIR /src/client
COPY client/pubspec.yaml client/pubspec.lock ./
RUN flutter pub get
COPY client/ ./
RUN flutter build web --target lib/console_main.dart --base-href=/console/ \
 && mv build/web /tmp/console-dist \
 && flutter build web --target lib/web_main.dart --base-href=/web/

# --- Server: compile the static Go binary with the web assets embedded
# (same layout as `make build`: internal/webconsole/dist, internal/webclient/dist). ---
FROM golang:1.26.7-alpine AS server
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY --from=web /tmp/console-dist ./internal/webconsole/dist
COPY --from=web /src/client/build/web ./internal/webclient/dist
RUN go build -trimpath -o /out/meridian ./cmd/meridian

# --- Runtime: minimal image; memo data lives at /data (a named volume in
# compose), so rebuilding the container keeps it. ---
FROM alpine:3.22
COPY --from=server /out/meridian /meridian
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/meridian"]
CMD ["-addr=:8080", "-data=/data"]
