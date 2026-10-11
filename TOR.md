# Tor mode: privacy, accountability, and appropriate use

[← Main README](README.md) · [Security policy](SECURITY.md)

Tor protects source-network privacy; it does not authorize an action or remove accountability.
Use it deliberately, with narrow destinations and minimal external authority.

## Contents

- [Purpose](#purpose)
- [What Tor mode changes](#what-tor-mode-changes)
- [Safeguards and boundaries](#safeguards-and-boundaries)
- [The attribution tradeoff](#the-attribution-tradeoff)
- [Appropriate uses](#appropriate-uses)
- [Uses to avoid](#uses-to-avoid)
- [Recommended operating baseline](#recommended-operating-baseline)
- [Monitor and logs](#interpreting-the-monitor-and-logs)
- [Decision checklist](#decision-checklist)
- [Guiding principle](#guiding-principle)

## Purpose

Tor mode is an explicit privacy option for agent tool traffic. It reduces disclosure of the
operator's source network while also reducing destination-side attribution. This guide explains
when that tradeoff is appropriate and where the technical safeguards stop.

## What Tor mode changes

With `-Tor`, traffic handled by Squid—such as MCP, Git, package-manager, `curl`, and other tool
traffic—is forced through the dedicated Privoxy/Tor gateway:

```text
agent ── internal network ── Squid ── internal transit ── Privoxy/Tor ── public endpoint
  └──────────────────────── API proxy ── direct TLS ── Ollama model API
```

The public tool endpoint sees a Tor exit address rather than the operator's source address. Model
API requests remain on the separate direct API-proxy path, and the real model API key never enters
the Tor-routed agent path.

Tor mode does not provide bypass domains, direct fallback, bridges, exit-country selection, or
forced circuit rotation. The launcher rejects GitHub-authenticated Copilot mode and
`-NoKeyInjection` together with `-Tor` so those model credentials cannot enter the Tor path.

## Safeguards and boundaries

The design retains several important controls:

- Squid's destination and port allowlist is still enforced before traffic reaches Tor.
- Squid has no direct-egress interface in Tor mode and uses the Tor gateway as a mandatory parent.
- Startup fails unless Tor reaches full bootstrap and an external check confirms Tor routing.
- The localhost monitor and saved Squid logs preserve destination, timing, status, and byte-level
  evidence visible to this environment.
- The agent remains on an internal network without a direct internet route.

These controls constrain *where* traffic can go. They do not determine *what* an agent may do at an
allowed endpoint. If an allowlisted MCP server or web service supports writes, the agent may still
create, change, or delete external data according to the authority available to it.

## The attribution tradeoff

Tor intentionally separates an internet connection from its originating network. For public,
unauthenticated endpoints, that can make agent activity substantially harder for the destination
to attribute to the operator or organization. Shared exit addresses may also inherit poor
reputation, rate limits, blocks, or challenges caused by unrelated users.

Authentication changes the picture but does not remove the concern. An authenticated request still
identifies its account, token, tenant, or application even when its source address is a Tor exit.
Tor hides the network origin; it does not hide identities deliberately carried in the protocol or
request content.

The local monitor is useful operational evidence, not independent non-repudiation. A Windows user
who controls WSLc and the containers can also influence local state and logs. If an activity needs
third-party-verifiable attribution, regulatory auditability, or a stable organizational source
address, Tor mode is the wrong transport.

## Appropriate uses

Tor mode is most defensible for narrowly scoped, read-oriented activity such as:

- Reading public documentation or public repositories.
- Querying unauthenticated, read-only MCP services.
- Fetching non-sensitive public data from explicitly approved endpoints.
- Legitimate research where source-network privacy is a stated requirement.
- Testing how an owned service behaves when reached through privacy networks.

The destination allowlist should still contain only the hosts required for that session.

## Uses to avoid

Do not treat Tor mode as the routine default for agent activity. Avoid it for:

- Git pushes, issue creation, publishing, or other externally visible write operations.
- Authenticated MCP servers unless the privacy need and account-level attribution are understood.
- Production, customer, administrative, financial, or safety-critical APIs.
- Automated scanning, bulk collection, endpoint discovery, or activity prohibited by the target.
- Services that require organizational IP allowlisting or reliable source attribution.
- Work where policy, contract, law, or incident-response requirements mandate attributable egress.
- Plain HTTP carrying credentials or sensitive content; a Tor exit can observe or modify it.

An allowlisted destination is an available exfiltration and action channel. Tor does not reduce the
agent's authority at that destination.

## Recommended operating baseline

For a Tor-enabled session:

1. Define a legitimate, specific purpose before launch.
2. Use the narrowest possible `-AllowDomains` list; do not combine Tor with `-AllowAllDomains` for
   routine work.
3. Prefer public, read-only, unauthenticated endpoints.
4. Enable `-Monitor` and retain the saved proxy and Tor logs for the required review period.
5. Use `-NoAuto` when tools can change external state.
6. Prefer a new, disposable, or read-only workspace.
7. Do not place unrelated credentials, tokens, cookies, or sensitive datasets in the agent's reach.
8. Review the target's terms, automation rules, and rate limits before use.
9. Stop the session when its stated task is complete.

Example:

```powershell
.\Start-AgentSidecar.ps1 `
  -Tor `
  -Monitor `
  -NoAuto `
  -McpConfig .\mcp\opencode.json `
  -AllowDomains learn.microsoft.com, pisinger.tngx-voice.com
```

## Interpreting the monitor and logs

Squid cannot inspect encrypted MCP or HTTPS payloads. A persistent MCP client may reuse one
`CONNECT` tunnel for many tool calls. The monitor therefore shows the open tunnel, live byte
counters, and a reuse pulse—not the individual encrypted MCP method names. The completed Squid row
is written when the tunnel closes.

The monitor establishes what this sandbox observed:

- requested destination and resolved upstream address;
- whether Squid allowed or denied the connection;
- connection timing and byte counts;
- the Tor exit address verified at startup.

It does not prove the semantic intent of encrypted traffic, guarantee that the exit address never
rotated, or provide an audit record independent of the host operator.

## Decision checklist

Before enabling `-Tor`, answer all of these:

- Is hiding the source network necessary for this task rather than merely convenient?
- Are every destination and expected operation authorized?
- Can the task be limited to read-only, unauthenticated access?
- Is reduced destination-side attribution acceptable to the owner and organization?
- Are account identity and request content still capable of identifying the operator?
- Would a Tor exit's reputation, location, or instability create operational problems?
- Is the local evidence sufficient for the task's audit requirements?
- Is there a named person responsible for reviewing any external writes?

If any answer is unclear, use the normal non-Tor path until the governance question is resolved.

## Guiding principle

> Tor hides network origin; it does not make an action harmless, authorized, or unaccountable.

In this repository, `-Tor` should be treated as a high-intent privacy switch: explicit purpose,
narrow destinations, minimal authority, visible monitoring, and human accountability.
