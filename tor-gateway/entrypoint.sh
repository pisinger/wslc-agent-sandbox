#!/bin/sh
# Starts an unprivileged Privoxy -> Tor gateway and verifies the external path.
set -eu

TOR_LOG=/run/tor-gateway/tor.log
CHECK_URL=https://check.torproject.org/api/ip
TOR_PID=
PRIVOXY_PID=
TAIL_PID=

# shellcheck disable=SC2317 # invoked by trap
cleanup() {
  trap - EXIT INT TERM
  [ -z "$TAIL_PID" ] || kill "$TAIL_PID" 2>/dev/null || true
  [ -z "$PRIVOXY_PID" ] || kill "$PRIVOXY_PID" 2>/dev/null || true
  [ -z "$TOR_PID" ] || kill "$TOR_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

: > "$TOR_LOG"
tor -f /opt/tor-gateway/torrc > "$TOR_LOG" 2>&1 &
TOR_PID=$!
tail -n +1 -F "$TOR_LOG" &
TAIL_PID=$!
privoxy --no-daemon /opt/tor-gateway/privoxy.config &
PRIVOXY_PID=$!

# The launcher enforces the overall 60-second deadline. This loop also stops if either service dies.
while ! grep -q 'Bootstrapped 100%' "$TOR_LOG"; do
  kill -0 "$TOR_PID" 2>/dev/null || { echo "tor-gateway: Tor exited during bootstrap" >&2; exit 1; }
  kill -0 "$PRIVOXY_PID" 2>/dev/null || { echo "tor-gateway: Privoxy exited during bootstrap" >&2; exit 1; }
  sleep 1
done

RESULT=$(curl -fsS --max-time 20 --socks5-hostname 127.0.0.1:9050 "$CHECK_URL") \
  || { echo "tor-gateway: Tor verification request failed" >&2; exit 1; }
IS_TOR=$(printf '%s' "$RESULT" | jq -r '.IsTor // false')
EXIT_IP=$(printf '%s' "$RESULT" | jq -r '.IP // empty')
if [ "$IS_TOR" != "true" ] || [ -z "$EXIT_IP" ]; then
  echo "tor-gateway: verification did not confirm Tor" >&2
  exit 1
fi
printf 'tor-gateway: ready exit_ip=%s\n' "$EXIT_IP"

while kill -0 "$TOR_PID" 2>/dev/null && kill -0 "$PRIVOXY_PID" 2>/dev/null; do
  sleep 2
done
echo "tor-gateway: Tor or Privoxy exited" >&2
exit 1
