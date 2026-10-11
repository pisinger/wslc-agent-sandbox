#!/bin/sh
# Verifies that the agent container can reach the internet ONLY through the proxy sidecars.
# Runs in the entrypoint root phase when EGRESS_MODE=proxy. Fails closed.
#
# Env:
#   HTTPS_PROXY                required (set by the sidecar launcher)
#   PROXY_CHECK_DOMAIN         allowlisted host that must work via squid; empty = skip (empty allowlist)
#   PROXY_BLOCKED_TEST_DOMAIN  non-allowlisted host that must fail, default example.com
#   API_PROXY_URL              optional, API key injection proxy base URL (e.g. http://oc-api-x:8080)
#   API_KEY_PLACEHOLDER        optional, expected placeholder value of OLLAMA_API_KEY under injection
#   STRICT_DNS                 1 = fail if external DNS resolves (DNS tunnelling risk)
#   PROXY_ALLOW_ALL            1 = squid allows any domain; check 2 then verifies routing instead of denial
#   PROXY_ALLOW_HTTP           1 = plain HTTP :80 is allowed to the same destinations
set -eu

: "${HTTPS_PROXY:?HTTPS_PROXY not set}"
ALLOWED="${PROXY_CHECK_DOMAIN:-}"
BLOCKED="${PROXY_BLOCKED_TEST_DOMAIN:-example.com}"
fail() { echo "egress: FAIL, $1" >&2; exit 1; }

# 1. No direct route out: by name and by IP (IP test excludes "only DNS is missing").
curl -s --noproxy '*' --max-time 5 -o /dev/null "https://$BLOCKED" \
  && fail "direct internet access to $BLOCKED without proxy"
curl -sk --noproxy '*' --max-time 5 -o /dev/null "https://1.1.1.1" \
  && fail "direct internet access by IP without proxy"

# 2. Squid denies non-allowlisted hosts (allow-all mode: the same host must work THROUGH squid).
if [ "${PROXY_ALLOW_ALL:-0}" = "1" ]; then
  curl -s --max-time 15 -o /dev/null "https://$BLOCKED" \
    || fail "$BLOCKED not reachable through proxy in allow-all mode"
  echo "egress: WARNING, allow-all mode: no domain restriction, egress is logged only" >&2
else
  curl -s --max-time 10 -o /dev/null "https://$BLOCKED" \
    && fail "proxy allowed non-allowlisted $BLOCKED"
fi

# 3. Squid allows allowlisted hosts (skipped when the allowlist is intentionally empty).
if [ -n "$ALLOWED" ]; then
  curl -s --max-time 15 -o /dev/null "https://$ALLOWED" \
    || fail "$ALLOWED not reachable through proxy"
  if [ "${PROXY_ALLOW_HTTP:-0}" = "1" ]; then
    curl -fs --max-time 15 -o /dev/null "http://$ALLOWED" \
      || fail "$ALLOWED not reachable through proxy over plain HTTP"
  fi
fi

# 4. API key injection: proxy reachable, and the real key is NOT in this container.
if [ -n "${API_PROXY_URL:-}" ]; then
  curl -s --noproxy '*' --max-time 5 -o /dev/null "$API_PROXY_URL/healthz" \
    || fail "API proxy $API_PROXY_URL not reachable"
  if [ -n "${API_KEY_PLACEHOLDER:-}" ] && [ "${OLLAMA_API_KEY:-}" != "$API_KEY_PLACEHOLDER" ]; then
    fail "OLLAMA_API_KEY is not the placeholder; a real key may have been passed to the agent"
  fi
  # The model API host must not be directly reachable via squid when injection is on.
  curl -s --max-time 10 -o /dev/null "https://ollama.com" \
    && fail "ollama.com reachable via squid; remove it from the allowlist when using key injection"
fi

# 5. External DNS = DNS tunnelling path.
if nslookup "$BLOCKED" >/dev/null 2>&1; then
  [ "${STRICT_DNS:-0}" = "1" ] && fail "external DNS resolves $BLOCKED (STRICT_DNS=1)"
  echo "egress: WARNING, external DNS resolves; DNS tunnelling is possible" >&2
fi

echo "egress: proxy-only egress verified${API_PROXY_URL:+, API key injection active}"
