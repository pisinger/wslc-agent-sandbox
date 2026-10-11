# Security policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability that could expose credentials,
workspace data, or bypass an isolation control. Use GitHub's **Security** tab and select
**Report a vulnerability** to start a private advisory. Include the affected commit, launcher
options, WSL/WSLc versions, reproduction steps, observed result and expected result.

If private vulnerability reporting is not enabled for the repository, contact the maintainer
privately through the contact method on their GitHub profile before publishing details.

This is a proof of concept maintained on a best-effort basis. No response or remediation SLA is
promised. Please rotate any credential that may have been exposed during testing.

## Security scope

The intended default boundary is an unprivileged agent container attached only to an internal
WSLc network. General HTTPS egress terminates at an allowlisting Squid sidecar. Ollama requests
terminate at a separate API proxy which holds the real API key, strips agent-supplied credential
headers, restricts paths and models, and can enforce a request cap.

The launch-time self-test is part of the boundary: if direct routing, proxy denial, API-proxy
reachability or placeholder-key checks fail, the agent must not start.

With `-Tor`, all Squid-managed traffic is forced through an unprivileged Privoxy/Tor gateway on a
dedicated internal transit network. Squid has no direct-egress interface. The API proxy remains on
its separate direct path, so model traffic and the real Ollama key do not traverse Tor. Startup
requires Tor to reach 100% bootstrap and the Tor Project check endpoint to confirm the route.

## Trusted components

- The Windows user, WSL/WSLc runtime, container images and host are trusted.
- The launcher, API/Squid proxies, monitor and optional Tor gateway are trusted to create and
  preserve the topology.
- The agent, its prompts, generated commands, dependencies and workspace content are untrusted.
- Anyone able to run `wslc` as the same Windows user is effectively an administrator of these
  sessions and can reconnect networks or inspect container environments.

This project is not a hostile multi-tenant boundary and does not claim hardware-backed isolation.

## Known limitations

- Allowed destinations are data-exfiltration channels. Keep `-AllowDomains` minimal.
- MCP tools extend the agent's authority and may contain credentials or perform writes. Review each
  server and its exposed tools, keep MCP config files out of source control when they contain
  secrets, and pair remote servers with the narrowest practical destination allowlist.
- `-AllowHttp` permits unencrypted traffic on port 80. Requests, responses and credentials sent
  over HTTP can be observed or modified in transit; prefer HTTPS whenever possible.
- Tor exit relays can observe and modify plain HTTP. Tor hides the source network, not identities
  disclosed by accounts, tokens, cookies, prompts or application content.
- Tor exits are frequently blocked or challenged, add latency, and can change naturally during a
  session. The verified exit IP is evidence from startup, not a guarantee for every later stream.
- Authenticated MCP traffic may use Tor and still identifies its account. Copilot GitHub auth and
  `-NoKeyInjection` are rejected in Tor mode so model credentials never enter the Tor-routed path.
- Tor mode supports the standard public Tor network only: no bridges, pluggable transports, exit
  selection, direct fallbacks or bypass domains. Onion services have no exit relay.
- `-AllowAllDomains` deliberately removes destination restriction. Traffic remains routed and
  logged, but an agent can send accessible data or credentials to any HTTPS destination.
- `-NoKeyInjection` places the real Ollama key inside the agent container.
- GitHub authentication places a GitHub identity inside the agent container. Prefer a
  least-privilege, short-lived token and a read-only or disposable workspace.
- The agent can use the protected Ollama key indirectly through the API proxy, subject to its
  configured path, model and request limits. Those controls are not a spending guarantee.
- Squid does not inspect TLS. It trusts the requested destination hostname, so domain fronting or
  abuse of an allowed shared service may evade destination intent.
- External DNS may remain reachable on some WSLc builds and can become a tunnelling channel. Use
  `-StrictDns` and verify the launch-time result when this matters.
- A writable host workspace lets an agent alter source, Git hooks, editor tasks and build scripts
  that may later execute on the host. Prefer `-WorkspaceReadOnly` for review or a disposable
  worktree for changes, and inspect diffs before running host-side tools.
- `-RunAsRoot` gives the agent UID 0 inside its container. Network capabilities and the external
  topology remain constrained, but the agent can rewrite its container and create root-owned
  workspace files.
- The shared `opencode-cache` volume carries state between OpenCode sessions.
- The monitor receives logs over UDP, so its live view can lose rows under load. Saved proxy logs
  are the audit source.
- The monitor has no application authentication. The launcher therefore requires a
  `127.0.0.1` bind and rejects wildcard, LAN and empty bind addresses.
- In Tor mode the monitor has a normal interface for localhost port publication and an internal
  interface for Squid logs. Squid never joins the monitor's normal network, so that interface is
  not a Squid bypass path. The monitor remains a trusted component.
- Container tags and packages can change between builds unless the operator pins versions and
  image digests.

## Safe operating baseline

Use key injection, a narrow allowlist, the non-root agent, `-NoAuto`, and a new, read-only or
disposable workspace. Enable `-StrictDns` where DNS egress is unacceptable. Treat
`-AllowAllDomains`, `-NoKeyInjection`, GitHub authentication and `-RunAsRoot` as explicit reductions
of the default posture.
