#!/bin/sh
# Renders allowlist + runtime settings from env, validates config, starts squid in the foreground.
#
# Env:
#   PROXY_ALLOW_DOMAINS  required, space list. "example.com" = exact host,
#                        ".example.com" = domain and all subdomains.
#                        Do not list both forms of the same domain (squid rejects it).
#   PROXY_HOSTNAME       optional, visible_hostname; must match the name the monitor uses
#   MGR_PASSWORD         optional, cache manager password (16-64 alphanumerics). Unset = manager disabled
#   VIEWER_LOG_TARGET    optional, host:port of the monitor UDP log receiver
#   PROXY_ALLOW_ALL      optional, 1 = allow CONNECT :443 to ANY domain (logging only, no allowlist)
#   PROXY_ALLOW_HTTP     optional, 1 = also allow plain HTTP :80 to allowed domains
#   PROXY_DENY_DOMAINS   optional, space list always denied; evaluated before the allowlist / allow-all
#   API_PROXY_HOST       optional, name of the API key injection proxy. Plain-HTTP requests to
#                        <API_PROXY_HOST>:8080 are forwarded (for clients that ignore NO_PROXY).
#   PROXY_PARENT_HOST    optional HTTP parent proxy on :8118. All upstream traffic is forced
#                        through it with no direct fallback (used by Tor mode).
set -eu

LIST=/run/squid/allowed_domains.txt
RUNTIME=/run/squid/runtime.conf
umask 077

: > "$LIST"
for d in ${PROXY_ALLOW_DOMAINS:-}; do
  d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$d" | grep -Eq '^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
    || { echo "proxy: rejected domain '$d'" >&2; exit 1; }
  echo "$d" >> "$LIST"
  echo "proxy: allow $d"
done
if [ ! -s "$LIST" ]; then
  # Empty allowlist is valid (e.g. Copilot with key injection needs no direct egress at all).
  echo "allowlist.invalid" > "$LIST"
  echo "proxy: allowlist empty, all CONNECT requests are denied"
fi

HOST="${PROXY_HOSTNAME:-egress-proxy}"
printf '%s' "$HOST" | grep -Eq '^[a-z0-9][a-z0-9.-]*$' || { echo "proxy: invalid PROXY_HOSTNAME" >&2; exit 1; }
echo "visible_hostname $HOST" > "$RUNTIME"

if [ -n "${MGR_PASSWORD:-}" ]; then
  printf '%s' "$MGR_PASSWORD" | grep -Eq '^[A-Za-z0-9]{16,64}$' || { echo "proxy: invalid MGR_PASSWORD format" >&2; exit 1; }
  echo "cachemgr_passwd $MGR_PASSWORD all" >> "$RUNTIME"
  echo "proxy: cache manager enabled (password protected)"
else
  echo "cachemgr_passwd disable all" >> "$RUNTIME"
fi

if [ -n "${API_PROXY_HOST:-}" ]; then
  printf '%s' "$API_PROXY_HOST" | grep -Eq '^[a-z0-9][a-z0-9.-]*$' || { echo "proxy: invalid API_PROXY_HOST" >&2; exit 1; }
  {
    echo "acl api_proxy_host dstdomain $API_PROXY_HOST"
    echo "acl api_proxy_port port 8080"
    echo "http_access allow api_proxy_host api_proxy_port localnet"
  } >> "$RUNTIME"
  echo "proxy: forwarding plain HTTP to $API_PROXY_HOST:8080 (API key injection)"
fi

if [ -n "${PROXY_PARENT_HOST:-}" ]; then
  printf '%s' "$PROXY_PARENT_HOST" | grep -Eq '^[a-z0-9][a-z0-9.-]*$' \
    || { echo "proxy: invalid PROXY_PARENT_HOST" >&2; exit 1; }
  {
    echo "cache_peer $PROXY_PARENT_HOST parent 8118 0 no-query default"
    echo "never_direct allow all"
  } >> "$RUNTIME"
  echo "proxy: forcing all upstream traffic through parent $PROXY_PARENT_HOST:8118"
fi

# Deny list first, so it also wins over PROXY_ALLOW_ALL.
if [ -n "${PROXY_DENY_DOMAINS:-}" ]; then
  for d in $PROXY_DENY_DOMAINS; do
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    printf '%s' "$d" | grep -Eq '^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
      || { echo "proxy: rejected deny domain '$d'" >&2; exit 1; }
    echo "acl denied_domains dstdomain $d" >> "$RUNTIME"
    echo "proxy: deny $d"
  done
  echo "http_access deny denied_domains" >> "$RUNTIME"
fi

if [ "${PROXY_ALLOW_ALL:-0}" = "1" ]; then
  # HTTPS remains CONNECT-only on port 443. No domain restriction.
  echo "http_access allow CONNECT SSL_ports localnet" >> "$RUNTIME"
  echo "proxy: WARNING, allow-all mode: CONNECT :443 to any domain (logged, not restricted)"
fi

if [ "${PROXY_ALLOW_HTTP:-0}" = "1" ]; then
  if [ "${PROXY_ALLOW_ALL:-0}" = "1" ]; then
    echo "http_access allow HTTP_ports localnet" >> "$RUNTIME"
    echo "proxy: WARNING, allowing plain HTTP :80 to any domain (content is not encrypted)"
  else
    echo "http_access allow HTTP_ports allowed_domains localnet" >> "$RUNTIME"
    echo "proxy: WARNING, allowing plain HTTP :80 to allowlisted domains (content is not encrypted)"
  fi
fi

if [ -n "${VIEWER_LOG_TARGET:-}" ]; then
  printf '%s' "$VIEWER_LOG_TARGET" | grep -Eq '^[a-z0-9][a-z0-9.-]*:[0-9]{1,5}$' \
    || { echo "proxy: invalid VIEWER_LOG_TARGET" >&2; exit 1; }
  echo "access_log udp://$VIEWER_LOG_TARGET viewer" >> "$RUNTIME"
  echo "proxy: streaming access log to udp://$VIEWER_LOG_TARGET"
fi

# 'squid -k parse' echoes every directive, including the password. Show errors only, redacted.
if ! squid -k parse -f /etc/squid/squid.conf >/dev/null 2>&1; then
  squid -k parse -f /etc/squid/squid.conf 2>&1 | grep -v 'cachemgr_passwd' >&2
  exit 1
fi
exec squid -N -f /etc/squid/squid.conf
