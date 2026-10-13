# Operations guide

[← Main README](../README.md) · [Configuration reference](CONFIGURATION.md) · [Security policy](../SECURITY.md) · [Tor mode guide](../TOR.md)

Build and run sessions, use common recipes, inspect traffic, verify isolation, and troubleshoot failures. PowerShell examples assume the current directory is the repository root.

## Contents

- [Recipes](#recipes)
- [Egress self-test](#egress-self-test)
- [Egress monitor](#egress-monitor)
- [Logs](#logs)
- [Why a sidecar, not an in-container firewall](#why-a-sidecar-not-an-in-container-firewall)
- [Security model and limits](#security-model-and-limits)
- [Verify inside a session](#verify-inside-a-session)
- [Troubleshooting](#troubleshooting)

## Recipes

Practical combinations of the launcher parameters. All commands run from the project root in PowerShell.

### Build all images

`Build-AgentImages.ps1` builds every image with the tags the launcher expects, stops at the first
failed build and prints a summary table.

```powershell
.\Build-AgentImages.ps1                                     # everything
.\Build-AgentImages.ps1 -Agent opencode                     # opencode agent image + all sidecars
.\Build-AgentImages.ps1 -Agent copilot                      # Copilot agent image + all sidecars ("github" also works)
.\Build-AgentImages.ps1 -Images api-proxy,proxy             # selected images only
.\Build-AgentImages.ps1 -Exclude tor-gateway,monitor        # skip optional images
.\Build-AgentImages.ps1 -Agent copilot -AgentVersion 1.0.4 -NoCache   # pinned CLI, clean rebuild
```

| Parameter | Effect |
|---|---|
| `-Agent all\|opencode\|copilot\|github` | Which agent image to build (default `all`; `github` = `copilot`). Sidecar images are unaffected |
| `-Images` | `all` (default) or a list of `opencode`, `copilot`, `api-proxy`, `proxy`, `monitor`, `tor-gateway` |
| `-Exclude` | Images to skip from the selection |
| `-AgentVersion` | `--build-arg AGENT_VERSION=<version>` for the agent images, pins the CLI |
| `-AlpineVersion` | `--build-arg ALPINE_VERSION=<version>` for all images (default in the Dockerfiles: 3.22) |
| `-NoCache` | `--no-cache` for a clean rebuild |

Equivalent manual commands:

```powershell
wslc build -t opencode-alpine:local --build-arg AGENT=opencode agent
wslc build -t copilot-alpine:local  --build-arg AGENT=copilot  agent
wslc build -t agent-egress-proxy:local   proxy
wslc build -t agent-api-proxy:local      api-proxy
wslc build -t agent-egress-monitor:local monitor
wslc build -t agent-tor-gateway:local    tor-gateway   # optional
```

`wslc image ls` shows the creation time of each tag.

### Choose agent and model

```powershell
.\Start-AgentSidecar.ps1                                                   # opencode, default model
.\Start-AgentSidecar.ps1 -Models "qwen3-coder:480b,deepseek-v4.1-flash"     # first entry = default
.\Start-AgentSidecar.ps1 -Agent copilot                                    # Copilot BYOK, Responses API
.\Start-AgentSidecar.ps1 -Agent copilot -CopilotWireApi completions        # only if a model lacks the Responses API
.\Start-AgentSidecar.ps1 -Agent copilot -CopilotAuth github                # GitHub models, PAT from vault/env
.\Start-AgentSidecar.ps1 -NoAuto                                           # approve every tool call
```

### Session packages (`-ApkPackages`)

Extra Alpine packages for one session, installed as root **before** the privilege drop. The agent can use them but can't install anything itself.

```
launcher -ApkPackages "python3 py3-pip"
  1. adds dl-cdn.alpinelinux.org to the squid allowlist
  2. passes EXTRA_APK_PACKAGES to the agent container
entrypoint, root phase
  3. validates each name (^[a-z0-9][a-z0-9._+-]*$, blocks option injection)
  4. apk add --no-cache ...  via squid (CONNECT dl-cdn.alpinelinux.org:443)
  5. egress self-test
  6. drop to user "agent": no capabilities, no_new_privs
```

```powershell
.\Start-AgentSidecar.ps1 -ApkPackages "python3 py3-pip"
.\Start-AgentSidecar.ps1 -Agent copilot -ApkPackages "go make"
.\Start-AgentSidecar.ps1 -ApkPackages "nodejs-dev build-base"
```

- **Lifetime:** packages are downloaded again on every start, because the container is `--rm`. Anything used in most sessions belongs in `agent/Dockerfile`.
- **Fail closed:** an unknown package or an unreachable CDN stops the container start.
- **HTTPS only:** the image's repositories must use `https://` (squid blocks plain HTTP). Check once: `wslc run --rm --entrypoint cat opencode-alpine:local /etc/apk/repositories`.

### Agent as root (`-RunAsRoot`)

By default the agent runs as the unprivileged `agent` user and can't install anything. With `-RunAsRoot` it runs as root, so it can `apk add` whatever a task needs, at runtime and on its own.

```powershell
.\Start-AgentSidecar.ps1 -RunAsRoot
.\Start-AgentSidecar.ps1 -Agent copilot -RunAsRoot -Monitor
#   inside: apk add --no-cache python3 py3-pip jq
```

| Aspect | Default (`agent`) | `-RunAsRoot` |
|---|---|---|
| UID | 1000 | 0 |
| Capabilities | none | only `chown`, `dac_override`, `fowner`, `fsetid` (what `apk` needs for package files) |
| Dropped in both | `NET_RAW`, `NET_ADMIN`, `SETUID`, `SETGID`, `KILL`, `MKNOD`, `SYS_CHROOT`, ... | same |
| `no_new_privs` | on | on: setuid binaries (e.g. from an installed `sudo`) still gain nothing |
| `apk add` | not possible (use `-ApkPackages`) | possible; only signed packages from the image's root-owned repositories |
| Allowlist | as configured | `dl-cdn.alpinelinux.org` added automatically |
| Network isolation, squid, key injection | unchanged | unchanged |

**What the agent gains as root:** it can modify everything inside its own container: binaries, configs, the entrypoint scripts and the Alpine repository list. All of that is discarded on exit (`--rm`). Files it creates in `/workspace` are owned by root.

**What it still can't do:** reach the internet except through squid, change routes or firewall rules (no `NET_ADMIN`), open raw sockets (no `NET_RAW`), read the real Ollama key (still only in the API proxy), or escalate further via setuid.

**Prefer `-ApkPackages`** when you know the packages up front: the agent then stays unprivileged. Use `-RunAsRoot` for exploratory work where the agent decides what to install.

### Python work

Alpine's Python blocks system-wide `pip install` (PEP 668), so the agent must use a virtual environment.

```powershell
.\Start-AgentSidecar.ps1 -ApkPackages "python3 py3-pip" `
    -AllowDomains "models.dev registry.npmjs.org pypi.org files.pythonhosted.org"
```

Inside the session (or as an instruction to the agent): `python3 -m venv .venv && . .venv/bin/activate && pip install <pkg>`. Packages with native code may build from source on musl; add `build-base python3-dev` to `-ApkPackages` if they do.

### Node.js and npm projects

```powershell
.\Start-AgentSidecar.ps1 -AllowDomains "models.dev registry.npmjs.org"              # opencode default already includes npm
.\Start-AgentSidecar.ps1 -Agent copilot -AllowDomains "registry.npmjs.org"          # Copilot default allowlist is empty
```

### Git over HTTPS

Only HTTPS clone URLs work; SSH (`git@github.com:...`, port 22) and `git://` (port 9418) are blocked.

```powershell
.\Start-AgentSidecar.ps1 -AllowDomains "models.dev registry.npmjs.org github.com codeload.github.com .githubusercontent.com"
```

Inside the session: `git clone https://github.com/<org>/<repo>.git`. Read-only cloning needs no credentials; keep tokens out of the agent where possible.

### MCP servers

For predictable behavior across both agents, provide MCP tools before the session starts. Pass an
agent-native JSON file with `-McpConfig`; the launcher validates it and mounts it read-only before
starting the CLI. This avoids depending on live config reload behavior in a particular CLI version.

The included configurations enable both the public Microsoft Learn MCP server and the Pisinger
Microsoft Security Release Radar MCP server. For OpenCode, use its normal top-level `mcp` format
([`mcp/opencode.json`](../mcp/opencode.json)):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "microsoft-learn": {
      "type": "remote",
      "url": "https://learn.microsoft.com/api/mcp",
      "enabled": true
    },
    "ms-release-radar": {
      "type": "remote",
      "url": "https://pisinger.tngx-voice.com/api/mcp",
      "enabled": true
    }
  }
}
```

For Copilot CLI, use its `mcpServers` format instead
([`mcp/copilot.json`](../mcp/copilot.json)):

```json
{
  "mcpServers": {
    "microsoft-learn": {
      "type": "http",
      "url": "https://learn.microsoft.com/api/mcp",
      "tools": ["*"]
    },
    "ms-release-radar": {
      "type": "http",
      "url": "https://pisinger.tngx-voice.com/api/mcp",
      "tools": ["*"]
    }
  }
}
```

Start the session with the config file and MCP hostname added to the usual destinations:

```powershell
.\Start-AgentSidecar.ps1 `
  -McpConfig .\mcp\opencode.json `
  -AllowDomains "models.dev registry.npmjs.org learn.microsoft.com pisinger.tngx-voice.com"
```

For Copilot, select that agent and pass its config file:

```powershell
.\Start-AgentSidecar.ps1 -Agent copilot `
  -McpConfig .\mcp\copilot.json `
  -AllowDomains "learn.microsoft.com pisinger.tngx-voice.com"
```

OpenCode receives the file through `OPENCODE_CONFIG`; its generated global model/provider config is
still merged normally. Copilot receives it as `~/.copilot/mcp-config.json`. Restart the session after
changing the host file so the agent discovers the new tool set. Do not commit MCP files containing
tokens or static authorization headers; prefer the server's OAuth flow or environment references.

A remote MCP server is another outbound HTTPS destination, so its hostname must be present in the
Squid allowlist. Supplying the MCP config does not grant network access by itself.

`-AllowDomains` replaces the scenario's default list; it does not append to it. Preserve any
default hosts that the selected agent still needs. HTTPS MCP endpoints use `CONNECT :443` and do
not need `-AllowHttp`. If the endpoint redirects or authenticates through another hostname, add
that hostname as well. Use `-AllowAllDomains -Monitor` for a short discovery run, then return to a
narrow explicit allowlist.

### Route tool traffic through Tor

Before enabling it, read [Tor mode: privacy, accountability, and appropriate use](../TOR.md). Tor can
protect the operator's source-network privacy, but it also reduces destination-side attribution of
agent activity and is not appropriate for every workload.

Build the optional gateway once, then add `-Tor`:

```powershell
.\Build-AgentImages.ps1 -Images tor-gateway
.\Start-AgentSidecar.ps1 -Tor -Monitor
```

Tor mode applies to every request handled by Squid: MCP, Git, package managers, curl and other
tool traffic. The normal domain allowlist remains in force before traffic reaches Tor. Ollama
model requests do **not** use Tor; they retain the separate, direct API-proxy path with key
injection, model controls and request limits.

```text
agent ── internal agent network ── Squid ── internal Tor transit ── Privoxy ── Tor ── internet
              └────────────────── API proxy ───────────────────────── direct ── Ollama
```

The Tor gateway is unprivileged, exposes no host ports, keeps ephemeral state, and verifies both
100% bootstrap and `IsTor: true` using `https://check.torproject.org/api/ip`. Startup continues as
soon as verification succeeds; `-TorStartTimeoutSec` is a maximum wait. A failure aborts the
session—Squid has no direct-egress interface and its configuration forbids direct fallback.

With `-Monitor`, the monitor keeps its normal localhost-published interface and also joins the
internal Tor transit network for Squid logs and cache-manager access. Squid does not join the
monitor's normal network, so this does not create a direct-egress bypass.

Constraints and caveats:

- `-Tor` cannot be combined with `-CopilotAuth github` or `-NoKeyInjection`, because those modes
  would place model traffic and its credentials on the general Squid path.
- There are no bypass domains, bridges, country selection or forced circuit rotations.
- Some services block Tor exits or trigger additional authentication checks. There is no direct
  fallback.
- Authenticated MCP traffic still identifies its account even though Tor hides the source address.
- `-AllowHttp` works, but a Tor exit can read and modify unencrypted HTTP traffic.
- Exact `.onion` hostnames may be placed in `-AllowDomains`; HTTP onion services also require
  `-AllowHttp`. The monitor's displayed exit IP applies to ordinary internet traffic, not onion
  services.
- Tor transports TCP only. It adds latency and is not an application-anonymity guarantee.

### Work on an existing repository

```powershell
.\Start-AgentSidecar.ps1 -Workspace C:\src\myrepo -WorkspaceReadOnly        # review and analysis
git -C C:\src\myrepo worktree add C:\work\agent-task                        # changes: separate worktree
.\Start-AgentSidecar.ps1 -Workspace C:\work\agent-task
wslc volume create agent-ws
.\Start-AgentSidecar.ps1 -Workspace agent-ws                                 # wslc volume, fastest for large repos
```

### Find out which domains a task needs

Run once with allow-all and the monitor, then pin the result:

```powershell
.\Start-AgentSidecar.ps1 -AllowAllDomains -Monitor
# Destinations panel: note the hosts the task used
.\Start-AgentSidecar.ps1 -AllowDomains "models.dev registry.npmjs.org <hosts from the panel>"
```

Without `-AllowHttp`, allow-all still means **HTTPS on port 443 only**:

| Request | Result |
|---|---|
| `curl -I https://bing.com` | allowed (`CONNECT bing.com:443`) |
| `curl -I bing.com:443` | **denied**: no scheme means `http://`, so curl sends plain HTTP to port 443 |
| `curl -I http://bing.com` | **denied**: plain HTTP |
| `git clone git@github.com:org/repo.git` | **denied**: SSH, port 22 |

For a legacy HTTP endpoint, opt in explicitly:

```powershell
.\Start-AgentSidecar.ps1 -AllowDomains "legacy.example.com" -AllowHttp
# Or, for discovery only: -AllowAllDomains -AllowHttp -Monitor
```

`curl http://legacy.example.com/path` then sends an absolute-URI request through Squid on port
80. HTTPS continues to use `CONNECT` on port 443. Direct proxy bypass still has no route.

Tools must use `https://` URLs explicitly.

### Cost and model control

```powershell
.\Start-AgentSidecar.ps1 -Models "deepseek-v4.1-flash" -MaxModelRequests 200 -Monitor   # cap per session
.\Start-AgentSidecar.ps1 -Agent copilot -ForceStreamUsage -Monitor                      # token counts for every stream
.\Start-AgentSidecar.ps1 -AnyModel                                                      # disable the model allowlist
```

Monitor filters for the same purpose: `code == API_DENIED` (blocked model or cap), `model contains qwen`, `tout > 2000`.

### Comparing agents

Run the same task with both agents and compare the API proxy rows in the monitor: requests per task, `Tok in` per request, and `Duration` per request. To separate model time from agent time after a session:

```powershell
$log = Get-ChildItem C:\temp\wslc-agent-sessions\_proxy-logs\*-oc-api.log | Sort-Object LastWriteTime | Select-Object -Last 1
$rows = Get-Content $log | Where-Object { $_ -match '^\d+\.\d+ \d+ .* API_INJECT ' } | ForEach-Object {
    $f = $_ -split ' '; [pscustomobject]@{ Start = [double]$f[0]; DurS = [int]$f[1] / 1000 } }
$gaps = for ($i = 1; $i -lt $rows.Count; $i++) { $rows[$i].Start - ($rows[$i-1].Start + $rows[$i-1].DurS) }
"{0} requests | model time {1:N1}s | agent gaps {2:N1}s" -f $rows.Count, ($rows | Measure-Object DurS -Sum).Sum, ($gaps | Measure-Object -Sum).Sum
```

### Inspect a running session

```powershell
wslc container ls                                                    # session, oc-proxy-*, oc-api-*, oc-monitor-*, optional oc-tor-gateway-*
wslc exec -it -u agent <session> sh                                   # shell as the agent user
wslc exec <session> sh -c "ip route"                                  # one-off command
wslc container logs -f oc-proxy-<session>                             # squid access log, live
wslc container logs -f oc-api-<session>                               # API proxy log, live
wslc container logs -f oc-tor-gateway-<session>                       # Tor bootstrap and verification
wslc exec oc-proxy-<session> cat /run/squid/runtime.conf              # effective squid rules (allow-all, deny list)
wslc run --rm --entrypoint sh copilot-alpine:local -c "command -v bash && copilot --version"   # check an image
```

## Egress self-test

Before the agent starts, `check-proxy-egress.sh` verifies the following. Any failure stops the container.

| Check | Expected |
|---|---|
| Direct HTTPS to `example.com` and to `1.1.1.1`, proxy bypassed | fails |
| `example.com` through squid | denied (allow-all mode: reachable through squid) |
| First allowlisted domain through squid | succeeds (skipped if the allowlist is empty; `github.com` in GitHub mode) |
| API proxy `/healthz` (injection) | reachable |
| `OLLAMA_API_KEY` in the agent (injection) | equals the placeholder |
| `ollama.com` through squid (injection) | denied |
| External DNS lookup | warning, or failure with `-StrictDns` |

## Egress monitor

`-Monitor` adds a live, Wireshark-style view on `http://localhost:8081`. The API proxy streams one
line per model request. Squid streams plain-HTTP requests individually, but encrypted HTTPS appears
as one `CONNECT` row per tunnel when it closes. API proxy lines show as `API_INJECT` (allowed) or
`API_DENIED` (path, model or cap violation), so model usage and blocked egress appear in one list.

The traffic table shows both the requested destination hostname and Squid's resolved upstream IP.
The resolved-IP field is blank when no upstream connection was made, such as an ACL denial.

```
normal: agent ── oc-int ── squid/API proxy ── oc-mon ── internet
                                         └── monitor ── 127.0.0.1:8081

Tor:    agent ── oc-int ── squid ── oc-tor (internal) ── Tor gateway ── internet
                            │             ├── monitor ── 127.0.0.1:8081
                            │             └── API proxy ── direct Ollama path
                            └── no direct-egress interface
```

In Tor mode the monitor starts on its normal host-published interface and additionally joins the
internal `oc-tor` network for UDP log delivery and Squid cache-manager polling. The API proxy also
joins `oc-tor` only for monitor delivery; its Ollama connection remains direct. Squid never joins
the monitor's normal network.

The **Model** column and the **Models** side panel show which model each API proxy request used, including denied attempts (sanitised: the name is agent-controlled input). Squid rows have no model, because their traffic is encrypted end to end. Click a model in the panel to filter on it.

**Token counts** (`Tok in`, `Tok out`, the Models panel and the status bar) come from the `usage` object in the model API's response. The API proxy reads it while streaming the response through, from plain JSON, SSE (chat completions, Responses API, Anthropic-style events) and NDJSON. It strips `Accept-Encoding` towards the upstream so bodies stay uncompressed and parseable. Streaming chat completions only report usage when the request asks for it: opencode does (its rendered config sets `includeUsage`), and for other clients `-ForceStreamUsage` makes the API proxy add the request field. Rows without counts mean the upstream didn't report usage for that request. The **Theme** button cycles Dark (default), Light and Auto (follows the OS); the choice is remembered in the browser.

Useful filters: `code == API_INJECT`, `code == API_DENIED`, `model contains qwen`, `model == deepseek-v4.1-flash && tout > 2000`, `verdict == denied`.

The display filter supports `==`, `!=`, `contains`, `matches`, and numeric `>`, `<`, `>=`, `<=` on the fields `host`, `port`, `client`, `method`, `model`, `tokens_in` (or `tin`), `tokens_out` (or `tout`), `code`, `status`, `verdict`, `url`, `server`, `sent`, `received`, `dur`, `no`. `&&` binds tighter than `||`.

**Limits of the view:**
- Squid logs `CONNECT` tunnels when they close. While they are open, the "Open tunnels" panel polls
  Squid every two seconds and shows their live sent/received socket counters; the footer includes
  those live bytes. A green pulse and byte deltas highlight a tunnel whenever it is reused. This
  reveals activity on a persistent MCP connection, but not individual encrypted calls.
- This is a connection and request log, not a packet capture. Byte counts are totals.
- UDP can drop lines under load. The saved logs in `_proxy-logs` are complete.

## Logs

On exit, the launcher saves to `<SessionRoot>\_proxy-logs\`:

| File | Content |
|---|---|
| `<session>-<timestamp>-oc-proxy.log` | Squid access log (all `CONNECT` and forwarded requests) |
| `<session>-<timestamp>-oc-api.log` | API proxy log: every model request with path, model, tokens in/out, status, bytes and duration; never the key |
| `<session>-<timestamp>-oc-tor-gateway.log` | Tor bootstrap, SOCKS safety checks, verification result and Privoxy lifecycle |

## Why a sidecar, not an in-container firewall

An earlier design blocked egress with `iptables` inside the agent container. That needs `CAP_NET_ADMIN`, which wslc can't grant today: the default capability set doesn't include it, `wslc run --cap-add` is rejected as "not recognized" (upstream: microsoft/WSL PR #41681), and the Intune setting `AllowWSLContainerPrivileged` can strip it on managed devices even once supported.

The sidecar design needs no capabilities, and it is the stronger design anyway:

| Aspect | iptables in the agent container (removed) | Sidecar (this project) |
|---|---|---|
| Needs `--cap-add` | yes | no |
| Where the control lives | inside the container it protects | network layout in the VM, plus separate containers |
| Allowlist | IP addresses, break when CDN IPs rotate | domain names |
| DNS tunnelling | open via the allowed resolver | closed if internal DNS doesn't resolve external names |
| Audit | none | per-request logs, optional live monitor |

### What `--internal` does under the hood

```
 inside agent:  ip route
                172.x.0.0/16 dev eth0      <- subnet only, no "default via"  -> gate 1: ENETUNREACH
 in the VM:     FORWARD drop for traffic leaving the bridge                  -> gate 2
                no MASQUERADE for the subnet                                 -> gate 3
```

All three gates live in the VM, not in the container, and the agent has no capabilities to change
its own routes. Containers on an internal network can still communicate across its bridge (layer
2, no external routing). In normal mode the proxies terminate agent connections and open new ones
from their egress interfaces. In Tor mode Squid instead has only internal interfaces and must use
the Privoxy parent on `oc-tor`; only the Tor gateway opens the external tool connection. The API
proxy retains a separate direct interface for Ollama.

## Security model and limits

See [SECURITY.md](../SECURITY.md) for the repository's threat model, supported security scope,
known limitations and vulnerability-reporting process.

| Control | Effect |
|---|---|
| Internal network, single attachment | The agent has no route out; the gates live in the VM, not the container |
| Privilege drop | The agent runs as `agent` with no capabilities and `no_new_privs` |
| Squid allowlist | `CONNECT :443` to listed domains; optional plain HTTP :80 with `-AllowHttp`; may be empty |
| API key injection | The real key exists only in the API proxy container |
| Tor mode | Squid has no direct-egress interface, uses a mandatory parent, and starts only after Tor is externally verified |
| No GitHub identity (BYOK) | Copilot runs offline with BYOK; GitHub token variables are unset. `-CopilotAuth github` deliberately changes this |
| Self-test | Proves isolation and key absence at every start; fails closed |
| Root mode (`-RunAsRoot`) | Opt-in. Root UID with only file-ownership capabilities and `no_new_privs`; network and key controls unchanged |
| Resource limits | Agent fixed at 4 GB memory and 2 CPUs; proxies and monitor at 256 MB and 0.5 CPU. A runaway or hijacked agent can't starve the proxies that enforce egress (`--pids-limit` isn't available in wslc) |

**Known limits:**
- **The agent can use the key through the API proxy**, within the model allowlist and request cap.
- **Allowed domains remain channels.** Keep the squid allowlist minimal; with Copilot and injection it can be empty.
- **Squid trusts the requested hostname.** TLS isn't inspected, so domain fronting through a shared CDN is theoretically possible.
- **Tor hides the source network, not application identity.** Logins, tokens, cookies and request
  contents can still identify the user. Exit relays can observe and modify plain HTTP.
- **The displayed Tor exit IP is verification evidence, not a permanent identity.** Tor may rotate
  circuits naturally, and onion-service traffic has no exit relay.
- **External DNS** may resolve on internal networks depending on the wslc build; use `-StrictDns` to enforce.
- **`opencode-cache` is shared** across opencode sessions.
- **Host-side control:** anything that can run `wslc` as your user can reconnect networks or read container environments, including the API proxy's key.
- **Not yet verified on every wslc build:** `--internal` isolation, container-name DNS on internal networks, and `network connect` on running containers. The readiness checks and self-test catch failures.

## Verify inside a session

```powershell
wslc exec -it -u agent <session> sh
```
```sh
ip route                                        # only the oc-int subnet, no "default"
grep -E 'Cap(Eff|Bnd)|NoNewPrivs' /proc/self/status
curl -m5 --noproxy '*' https://example.com      # fails: network unreachable
curl -m5 https://example.com                    # denied by squid
env | grep OLLAMA_API_KEY                       # "proxy-injected" with key injection
```

Note that `wslc exec` skips the entrypoint, so the shell doesn't carry the entrypoint's bounding-set drop. `CapEff` should still be 0 for the non-root `agent` user.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `This wslc build has no 'network create --internal'` | wslc too old; update WSL |
| `With API key injection, ollama.com must not be in -AllowDomains` | Remove it, or use `-NoKeyInjection` |
| `oc-api-<session> did not become ready` | API proxy image not built, or key missing (the log is printed) |
| `oc-tor-gateway-<session> did not become ready within 60 s` | Tor bootstrap or external verification did not finish; inspect the saved Tor log or retry with `-TorStartTimeoutSec 120` |
| `egress: FAIL, API proxy ... not reachable` | Container-name DNS on the internal network failed |
| `egress: FAIL, OLLAMA_API_KEY is not the placeholder` | A real key reached the agent; check custom changes to the launcher |
| Agent reports 403 `model '...' not allowed` | The model isn't in `-Models`; add it, or use `-AnyModel` |
| Agent reports 429 | `-MaxModelRequests` reached |
| Copilot errors on model calls | If the model rejects the Responses API, try `-CopilotWireApi completions`; check model IDs in the API proxy log |
| Copilot GitHub mode: login or model calls fail | Check `TCP_DENIED` in the squid log or monitor for a GitHub host missing from the allowlist, and add it with `-AllowDomains` (keep the defaults in the list) |
| Remote MCP server returns a Squid 403 or cannot connect | Add every MCP and authentication/redirect hostname to `-AllowDomains`; remember that specifying the parameter replaces the defaults |
| MCP tool calls do not create new monitor rows | Expected for HTTPS: the client reuses an encrypted `CONNECT` tunnel. Watch its live byte counters and green activity pulse under **Open tunnels**; the final row appears when the tunnel closes |
| Copilot GitHub mode asks to log in every session | No token and no `-CopilotHomeVolume`; use a token, or persist the CLI home |
| `/login` not available in Copilot | The session runs in BYOK mode (the default), or the image predates GitHub mode. Start with `-CopilotAuth github` and rebuild the Copilot image. The entrypoint prints a `copilot:` line in GitHub mode |
| Browser sign-in ends on `localhost:<port>` "not found" | The callback listener is inside the container. Use device-code sign-in or a PAT (see "Copilot with GitHub authentication") |
| `apk: rejected package name` | A name in `-ApkPackages` contains characters outside `a-z 0-9 . _ + -` |
| Container stops during `apk add` | Package doesn't exist for this Alpine version, or the CDN is unreachable (check `TCP_DENIED` for `dl-cdn.alpinelinux.org`, and that `/etc/apk/repositories` uses `https://`) |
| `ERR_ACCESS_DENIED` from squid in allow-all mode | The request was plain HTTP without `-AllowHttp`, or used a port other than 443/80. Prefer `https://`; enable `-AllowHttp` only when necessary |
| `apk add` inside the session: permission denied | The agent runs as `agent` (default). Use `-ApkPackages` at start, or `-RunAsRoot` |
| No model or token columns in the monitor | Expected in GitHub mode and with `-NoKeyInjection`: the API proxy isn't in the path. In scenarios 1 and 2, rows without counts mean the upstream didn't report usage; try `-ForceStreamUsage` |
| `egress: FAIL, direct internet access ...` | The internal network is not isolated on this wslc build; do not use this mode |
| `Proxy did not become ready` with `-Monitor` | Squid could not resolve the monitor for its UDP log target |
| Monitor port reports `WSAEADDRINUSE` | Another process owns the host port; stop it or select another one with `-MonitorPort` |
| Launcher says the monitor port is already in use | The preflight check found an existing listener before creating containers; choose a free port, e.g. `-MonitorPort 8082` |
| `-MonitorBind must be 127.0.0.1` | The unauthenticated monitor is intentionally localhost-only; remote binding is not supported |
| `-AllowDomains` reports an invalid domain | Pass hostnames only, either comma-separated (`-AllowDomains bing.com, example.com`) or as one quoted space-separated string (`-AllowDomains "bing.com example.com"`) |
| Monitor opens but stays empty in Tor mode | Rebuild any changed images—at minimum the monitor after UI/backend changes—and start a new session; existing containers do not acquire image changes |
| `wslc failed: network create` | Leftover network from a crashed session: remove `oc-int-<session>` and, when present, `oc-mon-<session>` / `oc-tor-<session>` |
