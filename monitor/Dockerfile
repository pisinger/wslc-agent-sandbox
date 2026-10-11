# Egress monitor: UDP access-log receiver + live web view (Python stdlib only).
# Build:  wslc build -t agent-egress-monitor:local monitor
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache python3 tini \
 && adduser -D -u 1000 monitor

COPY viewer.py index.html /opt/monitor/

USER monitor
EXPOSE 8080 5140/udp

ENTRYPOINT ["/sbin/tini", "--", "python3", "-u", "/opt/monitor/viewer.py"]
