# Egress proxy sidecar: Squid, allowlisted HTTPS :443 with optional plain HTTP :80.
# Build:  wslc build -t agent-egress-proxy:local proxy
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache squid tini \
 && mkdir -p /run/squid \
 && chown -R squid:squid /run/squid /var/cache/squid /var/log/squid

COPY --chown=squid:squid --chmod=0644 squid.conf /etc/squid/squid.conf
COPY --chmod=0755 proxy-entrypoint.sh /usr/local/bin/proxy-entrypoint.sh

# Runs fully unprivileged; port 3128 needs no capabilities.
USER squid
EXPOSE 3128

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD printf 'GET /squid-internal-mgr/info HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
        | nc -w 2 127.0.0.1 3128 \
        | grep -q '^HTTP/1\.[01] [2345][0-9][0-9]'

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/proxy-entrypoint.sh"]
