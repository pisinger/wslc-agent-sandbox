# Minimal example workload. The build script derives generic-alpine:local from this folder.
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache bash \
 && adduser -D -u 1000 -h /home/sandbox -s /bin/bash sandbox \
 && install -d -o sandbox -g sandbox /workspace

USER sandbox
WORKDIR /workspace
