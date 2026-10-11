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

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/proxy-entrypoint.sh"]
