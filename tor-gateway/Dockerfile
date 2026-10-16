# Optional Tor egress gateway: Privoxy converts Squid's HTTP-parent traffic to Tor SOCKS5.
# Build: wslc build -t agent-tor-gateway:local tor-gateway
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache tor privoxy curl jq ca-certificates tini \
 && install -d -o tor -g tor /var/lib/tor /var/log/tor /run/tor-gateway /opt/tor-gateway

COPY --chown=tor:tor torrc privoxy.config /opt/tor-gateway/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/tor-gateway-entrypoint.sh

USER tor
EXPOSE 8118

HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD nc -z 127.0.0.1 9050 && nc -z 127.0.0.1 8118 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/tor-gateway-entrypoint.sh"]
