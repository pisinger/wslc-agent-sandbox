# Agent image: Alpine + opencode OR GitHub Copilot CLI, configured at runtime for Ollama Cloud.
# Build (from the project root):
#   wslc build -t opencode-alpine:local --build-arg AGENT=opencode agent
#   wslc build -t copilot-alpine:local  --build-arg AGENT=copilot  agent
#
# Packages:
#   bash            Copilot CLI runs every shell command through bash (busybox sh is not enough)
#   libgcc/libstdc++ Bun-compiled opencode binary on musl
#   nodejs/npm      runtime for Copilot CLI and the opencode npm wrapper (Node 22 on Alpine 3.22)
#   git/ripgrep     agent tools        jq      config rendering
#   curl            egress self-test   setpriv privilege drop     tini PID 1
#
# Developer tools for agents (Alpine names in brackets where they differ):
#   ripgrep (rg), fd, yq (yq-go, mikefarah), shellcheck, shfmt, yamllint, actionlint
#   actionlint uses shellcheck for "run:" scripts in workflows when both are installed.
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

ARG AGENT=opencode
ARG AGENT_VERSION=latest

RUN apk add --no-cache \
        bash nodejs npm git ripgrep jq ca-certificates libgcc libstdc++ tini curl zip setpriv

RUN apk add --no-cache \
        fd yq-go shellcheck shfmt yamllint actionlint

RUN set -eu; \
    case "$AGENT" in \
      opencode) PKG="opencode-ai";     BIN="opencode" ;; \
      copilot)  PKG="@github/copilot"; BIN="copilot"  ;; \
      *) echo "unknown AGENT '$AGENT' (opencode|copilot)" >&2; exit 1 ;; \
    esac; \
    npm install -g --omit=dev "${PKG}@${AGENT_VERSION}"; \
    npm cache clean --force; \
    adduser -D -u 1000 -h /home/agent -s /bin/bash agent; \
    mkdir -p /workspace /home/agent/.cache/opencode /home/agent/.copilot; \
    chown -R agent:agent /workspace /home/agent

# Build gates: fail the build if bash, a developer tool or the agent CLI is missing.
RUN set -eu; \
    test -x /bin/bash; \
    for c in rg fd yq jq shellcheck shfmt yamllint actionlint git curl; do \
      command -v "$c" >/dev/null || { echo "missing tool: $c" >&2; exit 1; }; \
    done; \
    su agent -s /bin/bash -c "bash -c 'echo shell-ok'"; \
    case "$AGENT" in opencode) BIN=opencode ;; copilot) BIN=copilot ;; esac; \
    su agent -s /bin/sh -c "$BIN --version"

COPY --chmod=0755 entrypoint.sh check-proxy-egress.sh /usr/local/bin/

ENV HOME=/home/agent \
    SHELL=/bin/bash \
    AGENT=${AGENT} \
    OLLAMA_BASE_URL=https://ollama.com/v1

# Secure image default: the CLI and egress self-test run as the named, unprivileged user.
# The launcher overrides this to UID 0 only for -ApkPackages or the explicit -RunAsRoot mode;
# entrypoint then drops privileges after package installation unless root mode was requested.
USER agent
WORKDIR /workspace

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
