# API key injection proxy: the only place the model API key exists at runtime.
# Build:  wslc build -t agent-api-proxy:local api-proxy
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache python3 ca-certificates tini \
 && adduser -D -u 1000 apiproxy

COPY api_proxy.py /opt/api-proxy/api_proxy.py

USER apiproxy
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -Y off -O /dev/null "http://127.0.0.1:${API_PROXY_PORT:-8080}/healthz" || exit 1

ENTRYPOINT ["/sbin/tini", "--", "python3", "-u", "/opt/api-proxy/api_proxy.py"]
