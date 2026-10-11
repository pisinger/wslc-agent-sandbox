# Isolated agent sessions on WSL containers (wslc)

Isolated sessions for **opencode** or **GitHub Copilot CLI** on WSL containers, using Ollama Cloud models (default) or GitHub Copilot models. No extra container capabilities are needed:

- **Network isolation:** the agent runs on an internal network with no route out.
- **Egress allowlist:** a squid proxy is the only exit for general traffic, and forwards only allowlisted domains.
- **API key injection (default for Ollama):** a separate API proxy holds the real Ollama key and adds it to model requests. The agent only ever sees a placeholder.
- **Optional Tor mode:** general Squid traffic can be forced through an isolated Privoxy/Tor gateway while model API traffic stays direct through the API proxy.

```
                    oc-int-<session>  (internal: no gateway, no NAT)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ agent ──HTTP /v1/*──► API proxy ───────── direct HTTPS + real key ──► Ollama
 │   │
 │   └──HTTP(S) proxy──► Squid allowlist ──┬─ normal mode ─────────────► tools
 │                                         └─ Tor mode ─► Privoxy/Tor ─► tools
 └──────────────────────────────────────────────────────────────────────────┘
   agent: internal network only    Tor mode: Squid has no direct-egress interface
```

![WSLc sandbox architecture with direct model API and optional Tor tool egress](docs/sidecar-architecture.svg)

## Scenarios

| # | Scenario | Command | Containers | Secret inside the agent | Monitor shows model + tokens |
|---|---|---|---|---|---|
| 1 | opencode, Ollama (default) | `.\Start-AgentSidecar.ps1` | agent, squid, api-proxy | placeholder | yes |
| 2 | Copilot BYOK, Ollama | `.\Start-AgentSidecar.ps1 -Agent copilot` | agent, squid, api-proxy | placeholder | yes |
| 3 | Copilot, GitHub models, PAT | `.\Start-AgentSidecar.ps1 -Agent copilot -CopilotAuth github` | agent, squid | **GitHub PAT** | no (TLS to GitHub) |
| 4 | Copilot, GitHub models, device-code sign-in | as 3, plus `-CopilotHomeVolume copilot-home` | agent, squid | **GitHub token** (stored in the volume) | no (TLS to GitHub) |
| 5 | Ollama without injection (diagnostics) | add `-NoKeyInjection` to 1 or 2 | agent, squid | **Ollama key** | no (TLS to Ollama) |
| 6 | Any scenario, no domain restriction | add `-AllowAllDomains` | unchanged | unchanged | unchanged; squid rows for every destination |
| 7 | Agent as root (installs tools itself) | add `-RunAsRoot` | unchanged | unchanged | unchanged |
| 8 | Tool traffic through Tor | add `-Tor` to scenario 1 or 2 | + Tor gateway | placeholder | yes; monitor also shows verified exit IP |
| + | Live monitor | add `-Monitor` to any compatible scenario | + monitor | n/a | as per row |

Scenarios 1 and 2 are the hardened default. 3 to 5 trade key isolation and per-request visibility for functionality, and 6 trades the egress allowlist for convenience, so prefer them only when needed.

**What `-AllowAllDomains` keeps and drops:** the agent still has no route out (internal network), all traffic still goes through squid, and every connection is still logged and visible in the monitor. By default, only `CONNECT` to port 443 is allowed; plain HTTP and other ports stay blocked. What's gone is the destination restriction itself: a prompt-injected agent can send workspace content or a token it holds to any HTTPS site. With key injection the Ollama key remains protected, because it never enters the agent and `ollama.com` stays denied in squid.

Plain HTTP remains disabled by default. `-AllowHttp` additionally permits port 80 to the same
allowlisted destinations (or to any destination when combined with `-AllowAllDomains`). HTTP
requests and responses are unencrypted and can be read or modified in transit; use this only for
legacy endpoints that cannot serve HTTPS.

## Project layout

Each image has its own folder, which is also its build context: a build only sees the files in that folder.

```
opencode-wslc/
├── agent/                   agent image (opencode or Copilot CLI)
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── check-proxy-egress.sh
├── proxy/                   squid egress allowlist proxy
│   ├── Dockerfile
│   ├── squid.conf
│   └── proxy-entrypoint.sh
├── api-proxy/               API key injection proxy
│   ├── Dockerfile
│   └── api_proxy.py
├── monitor/                 live egress monitor (web UI)
│   ├── Dockerfile
│   ├── viewer.py
│   └── index.html
├── tor-gateway/             optional unprivileged Privoxy + Tor gateway
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── privoxy.config
│   └── torrc
├── docs/
│   └── sidecar-architecture.svg
├── mcp/                      ready-to-copy MCP configuration
│   ├── opencode.json
│   └── copilot.json
├── SECURITY.md              threat model, limitations and vulnerability reporting
├── Start-AgentSidecar.ps1   launcher (Windows host)
└── README.md
```

## Files

| File | Purpose |
|---|---|
| `agent/Dockerfile` | Agent image; `--build-arg AGENT=opencode` or `AGENT=copilot` |
| `agent/entrypoint.sh` | Root phase: packages, egress self-test, privilege drop. Agent phase: per-agent config, exec CLI |
| `agent/check-proxy-egress.sh` | Agent-side self-test, fails closed |
| `api-proxy/Dockerfile`, `api-proxy/api_proxy.py` | API key injection proxy (Python stdlib, non-root) |
| `proxy/Dockerfile`, `proxy/squid.conf`, `proxy/proxy-entrypoint.sh` | Squid allowlist proxy (non-root) |
| `monitor/Dockerfile`, `monitor/viewer.py`, `monitor/index.html` | Optional live egress monitor (web UI) |
| `tor-gateway/` | Optional fail-closed HTTP-parent-to-Tor gateway for Squid traffic |
| `mcp/*.json` | Microsoft Learn and Microsoft Security Release Radar MCP configuration in each agent's native format |
| `Start-AgentSidecar.ps1` | Launcher: networks, API proxy, squid, optional monitor, agent, teardown |
| `docs/sidecar-architecture.svg` | Architecture diagram |
| `SECURITY.md` | Supported security scope, known limitations and private reporting instructions |

## Prerequisites

- WSL containers with `wslc network create --internal` and `wslc network connect`; the launcher checks for `--internal` and refuses to start without it
- Scenarios 1, 2 and 5: an Ollama Cloud API key. Check the model IDs your key exposes, because `-Models` is also the API proxy's model allowlist: `curl https://ollama.com/v1/models -H "Authorization: Bearer $env:OLLAMA_API_KEY"`
- Scenarios 3 and 4: a GitHub account with a Copilot subscription. No Ollama key is needed

## Quick start

```powershell
# 1. Build the images (from the project root; each folder is its own build context)
wslc build -t opencode-alpine:local --build-arg AGENT=opencode agent
wslc build -t copilot-alpine:local  --build-arg AGENT=copilot  agent
wslc build -t agent-api-proxy:local api-proxy
wslc build -t agent-egress-proxy:local proxy
wslc build -t agent-egress-monitor:local monitor   # only for -Monitor
wslc build -t agent-tor-gateway:local tor-gateway  # only for -Tor

# 2. Store secrets once (optional, recommended)
Set-Secret -Name OllamaApiKey       -Secret (Read-Host "OLLAMA_API_KEY" -AsSecureString)   # scenarios 1, 2, 5
Set-Secret -Name CopilotGithubToken -Secret (Read-Host "GitHub PAT" -AsSecureString)       # scenario 3

# 3. Start a session
.\Start-AgentSidecar.ps1                      # opencode, key injection on
.\Start-AgentSidecar.ps1 -Agent copilot       # Copilot CLI, key injection on
.\Start-AgentSidecar.ps1 -Agent copilot -Monitor
.\Start-AgentSidecar.ps1 -Agent copilot -CopilotAuth github                      # GitHub models (PAT)
.\Start-AgentSidecar.ps1 -Agent copilot -CopilotAuth github -CopilotHomeVolume copilot-home   # device-code sign-in
.\Start-AgentSidecar.ps1 -Agent copilot -Workspace C:\src\myrepo -WorkspaceReadOnly   # existing folder
.\Start-AgentSidecar.ps1 -Tor -Monitor              # tool traffic via Tor; model API stays direct
```

### What needs rebuilding

The launcher does not build images automatically. Rebuild only the image whose source folder
changed, then start a new session; running containers never acquire rebuilt files.

| Changed path | Rebuild command |
|---|---|
| `agent/` | `wslc build -t opencode-alpine:local --build-arg AGENT=opencode agent` and/or the equivalent `copilot-alpine:local` build |
| `api-proxy/` | `wslc build -t agent-api-proxy:local api-proxy` |
| `proxy/` | `wslc build -t agent-egress-proxy:local proxy` |
| `monitor/` | `wslc build -t agent-egress-monitor:local monitor` |
| `tor-gateway/` | `wslc build -t agent-tor-gateway:local tor-gateway` |
| `Start-AgentSidecar.ps1`, `mcp/`, `README.md`, `SECURITY.md`, `docs/` | No image rebuild |

## Recipes

Practical combinations of the launcher parameters. All commands run from the project root in PowerShell.

### Build all images

```powershell
wslc build -t opencode-alpine:local --build-arg AGENT=opencode agent
wslc build -t copilot-alpine:local  --build-arg AGENT=copilot  agent
wslc build -t agent-egress-proxy:local   proxy
wslc build -t agent-api-proxy:local      api-proxy
wslc build -t agent-egress-monitor:local monitor
wslc build -t agent-tor-gateway:local    tor-gateway   # optional
```

Add `--no-cache` for a clean rebuild, and `--build-arg AGENT_VERSION=<version>` to pin the agent CLI. `wslc image ls` shows the creation time of each tag.

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
([`mcp/opencode.json`](mcp/opencode.json)):

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
([`mcp/copilot.json`](mcp/copilot.json)):

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

Build the optional gateway once, then add `-Tor`:

```powershell
wslc build -t agent-tor-gateway:local tor-gateway
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

## Agents

| Aspect | opencode | GitHub Copilot CLI |
|---|---|---|
| Image | `opencode-alpine:local` | `copilot-alpine:local` |
| Model config | `opencode.json` rendered at start (provider `@ai-sdk/openai-compatible`) | BYOK (default): `COPILOT_PROVIDER_BASE_URL`, `COPILOT_PROVIDER_API_KEY`, `COPILOT_MODEL`, `COPILOT_PROVIDER_TYPE=openai`. GitHub mode: the CLI's own GitHub models |
| GitHub contact | none | BYOK: none (`COPILOT_OFFLINE=true`, GitHub tokens unset). GitHub mode: yes, by design |
| Auto mode | `--auto` | `--allow-all` (tools, paths, URLs) |
| Default allowlist with injection | `models.dev registry.npmjs.org` (provider package and model catalog) | BYOK: **empty**, no direct egress at all |
| Default allowlist without injection | `ollama.com registry.npmjs.org models.dev` | BYOK: `ollama.com` |
| Default allowlist, GitHub mode | n/a | GitHub auth and Copilot API hosts (see below) |
| Cache volume | `opencode-cache` | none |

### Preinstalled tools

Both agent images ship these command-line tools; the build fails if one is missing.

| Command | Alpine package | Purpose |
|---|---|---|
| `rg` | `ripgrep` | fast code search |
| `fd` | `fd` | fast file search (`fd-find` on other distros) |
| `jq` | `jq` | JSON processing |
| `yq` | `yq-go` | YAML/JSON/XML processing (mikefarah's yq) |
| `shellcheck` | `shellcheck` | shell script linting |
| `shfmt` | `shfmt` | shell script formatting |
| `yamllint` | `yamllint` | YAML linting |
| `actionlint` | `actionlint` | GitHub Actions workflow linting; checks `run:` scripts with shellcheck |
| `git`, `curl`, `bash` | same | base tooling |

`yamllint` pulls in Python 3 as a dependency, so `python3` is available too (use a virtual environment for `pip`, see "Python work"). Additional tools per session: `-ApkPackages`; permanently: add them to `agent/Dockerfile`.

### Copilot with GitHub authentication (`-CopilotAuth github`)

By default Copilot runs as BYOK against Ollama, offline from GitHub. With `-CopilotAuth github` it runs "as usual": GitHub Copilot models via your subscription.

| Aspect | `byok` (default) | `github` |
|---|---|---|
| Models | Ollama Cloud via the API proxy | GitHub Copilot catalogue; optional `-CopilotModel` |
| Auth | Ollama key, injected by the API proxy | `COPILOT_GITHUB_TOKEN` from host env or vault secret `CopilotGithubToken`; otherwise device-code sign-in inside the CLI |
| API proxy | yes | not started (it only serves the Ollama API) |
| Squid allowlist default | empty | `github.com api.github.com .githubcopilot.com copilot-proxy.githubusercontent.com origin-tracker.githubusercontent.com` (from GitHub's Copilot allowlist reference) |
| Secret inside the agent | placeholder | **a GitHub token** (passed by name, or stored by the sign-in) |
| Monitor | model and token columns | squid `CONNECT` rows only; traffic to GitHub is end-to-end TLS |

**Login:**
- **Token (recommended):** a fine-grained PAT with only the "Copilot Requests" permission and a short expiry. Set it once with `Set-Secret -Name CopilotGithubToken -Secret (Read-Host -AsSecureString)`, or put it in `$env:COPILOT_GITHUB_TOKEN`.
- **Device-code sign-in:** without a token, use the CLI's **device-code** option (check `copilot login --help` for the exact flag in your version). It shows a code to enter at `github.com/login/device` in your host browser, with no callback needed.
- **Browser sign-in does not work** (e.g. the default `/login` flow). It redirects your Windows browser to a `localhost:<port>` callback that only exists inside the container, so the browser reports the page as not found. Workaround if you need it: copy the full failed callback URL from the address bar and deliver it into the container via stdin, never as a command argument, because it contains a one-time auth code: `wslc exec -i -u agent <session> sh -c 'read -r u; curl -s --noproxy "*" "$u" >/dev/null && echo delivered'`.
- **Persistence:** the agent container is `--rm`, so a sign-in is lost on exit unless you persist the CLI's home with `-CopilotHomeVolume copilot-home` (created if missing). That volume then holds a GitHub credential at rest: treat it as a secret, use it for one workspace or purpose, and `wslc volume rm` it when done.

**Monitor in GitHub mode:** the API proxy isn't in the path, so the Model and token columns stay empty. Squid only sees `CONNECT` rows to the GitHub hosts with byte totals, because the traffic is end-to-end TLS. Use the CLI's own usage display for per-session token counts.

**Risk compared with BYOK:** a GitHub token inside an `--allow-all` agent is an identity, not just a model key, and the GitHub hosts in the allowlist reopen ingress from arbitrary public content. Use `-NoAuto`, a minimal-permission token, and `-WorkspaceReadOnly` where possible.

**Copilot CLI notes:**
- **Wire API.** Copilot defaults to the OpenAI Responses API (`/v1/responses`). With chat completions, Copilot ran noticeably slower against Ollama Cloud in testing; use `-CopilotWireApi completions` only if a model doesn't support the Responses API.
- **Unattended behaviour.** Copilot CLI has open reports of the agent not writing files in some non-interactive runs. Interactive sessions are the tested path here.
- **First run on Alpine.** The image build runs `copilot --version` and fails if the CLI does not work on musl.

## API key injection

The API proxy (`oc-api-<session>`) is the only container that receives the real key.

| Control | Behaviour |
|---|---|
| Key handling | Real key passed to the API proxy by name only. The agent gets `OLLAMA_API_KEY=proxy-injected`. Incoming `Authorization`, `x-api-key`, `api-key` and `Cookie` headers are dropped and replaced by the real key |
| Fixed upstream | Only `https://ollama.com`. It is not an open proxy |
| Path allowlist | Only `/v1/*` (OpenAI-compatible API). Path traversal is rejected |
| Model allowlist | Requests naming a model outside `-Models` get 403. Disable with `-AnyModel` |
| Request cap | `-MaxModelRequests N` returns 429 after N requests per session, limiting runaway loops |
| Streaming | Responses are streamed as they arrive (SSE) |
| Logging | One line per request (method, path, status, bytes, duration), never headers or key. Lines also go to the monitor |
| No direct path | With injection, `ollama.com` must not be in the squid allowlist. The launcher refuses it and the self-test verifies it |

If an agent ignores `NO_PROXY` and sends the model request to squid instead, squid forwards plain HTTP for the API proxy host on port 8080, so injection still works.

**What injection does and does not solve:**
- **Solves:** the key can't be read or exfiltrated from the agent container, and stolen session state contains only the placeholder.
- **Does not solve:** the agent can still *use* the key through the proxy for any allowed model and path. The model allowlist and request cap limit that, and a low-limit dedicated key remains good practice.

## Running without key injection (`-NoKeyInjection`)

A diagnostic switch for Ollama scenarios. No API proxy is started; the agent receives the real key by name and calls `https://ollama.com/v1` through squid as an ordinary `CONNECT` tunnel.

| Item | With injection (default) | `-NoKeyInjection` |
|---|---|---|
| Key in the agent | placeholder | **real key**: readable via `env`, `/proc`, the agent's shell tool, and `wslc container inspect` on the host |
| Squid allowlist default | opencode: `models.dev registry.npmjs.org`; Copilot: empty | `ollama.com` added |
| Model allowlist, request cap, `-ForceStreamUsage` | enforced | **not applied** |
| Monitor | per-request rows with model and tokens | one `CONNECT` row per TLS tunnel, at close; no model or tokens |
| Self-test | + API proxy reachable, key is the placeholder, `ollama.com` blocked | those checks skipped |

Use it to rule out the API proxy when debugging, then switch back. Use a dedicated low-limit key and rotate it afterwards. It has no effect with `-CopilotAuth github`.

## Launcher parameters

| Parameter | Default | Description |
|---|---|---|
| `-SessionRoot` | `C:\temp\wslc-agent-sessions` | Parent folder for session workspaces and `_proxy-logs` |
| `-Session` | `oc-<yyyyMMdd-HHmmss>` | Session name; also names the containers and networks |
| `-Workspace` | empty (new session folder) | Existing host folder or existing wslc volume to mount as `/workspace` |
| `-WorkspaceReadOnly` | off | Mount the workspace read-only |
| `-Agent` | `opencode` | `opencode` or `copilot` |
| `-Models` | `deepseek-v4.1-flash` | Comma-separated model IDs; the first is the default, and the list is the API proxy's model allowlist |
| `-McpConfig` | empty | Agent-native MCP JSON loaded read-only before startup: OpenCode requires top-level `mcp`; Copilot requires top-level `mcpServers` |
| `-Image` | per agent | Agent image override |
| `-ApiProxyImage` | `agent-api-proxy:local` | API proxy image |
| `-ProxyImage` | `agent-egress-proxy:local` | Squid image |
| `-Tor` | off | Force all Squid-managed tool traffic through the optional Tor gateway; incompatible with GitHub Copilot auth and `-NoKeyInjection` |
| `-TorImage` | `agent-tor-gateway:local` | Privoxy + Tor gateway image |
| `-TorStartTimeoutSec` | `60` | Maximum wait for Tor bootstrap and external Tor verification |
| `-AllowDomains` | per agent and key mode (see Agents) | Squid allowlist as comma-separated PowerShell arguments or one quoted, space-separated string. `example.com` = exact host, `.example.com` = with subdomains. May be empty |
| `-AllowAllDomains` | off | Squid allows `CONNECT :443` to **any** domain: still routed, logged and monitored, but not restricted. `-AllowDomains` is ignored. With key injection, `ollama.com` stays denied |
| `-AllowHttp` | off | Also allow plain HTTP on port 80 to the selected domains. With `-AllowAllDomains`, allows HTTP :80 to any domain |
| `-ApkPackages` | empty | Session packages; `dl-cdn.alpinelinux.org` is added to the allowlist automatically |
| `-NoAuto` | off | Interactive approvals instead of auto mode |
| `-RunAsRoot` | off | Run the agent CLI as root, so it can install tools with `apk` itself. Same image; `dl-cdn.alpinelinux.org` is added to the allowlist. See "Agent as root" |
| `-NoKeyInjection` | off | Pass the real key to the agent; `ollama.com` is then allowlisted in squid |
| `-AnyModel` | off | Disable the API proxy's model allowlist |
| `-MaxModelRequests` | `0` (no cap) | API proxy request cap per session |
| `-ForceStreamUsage` | off | API proxy adds `stream_options.include_usage=true` to streaming chat requests that lack it, so token counts appear for every stream |
| `-CopilotWireApi` | `responses` | Copilot BYOK only: `responses` (faster with Copilot) or `completions` |
| `-CopilotAuth` | `byok` | Copilot only: `byok` (Ollama, offline from GitHub) or `github` (GitHub Copilot models, PAT or device-code sign-in) |
| `-CopilotModel` | empty | Copilot GitHub mode: model override, e.g. `claude-sonnet-4.6` |
| `-CopilotNodeOptions` | `--max-old-space-size=3072 --max-semi-space-size=64` | Copilot only: Node runtime flags. A larger young generation means fewer GC pauses at the cost of memory; keep `--max-old-space-size` below the agent's 4 GB limit |
| `-CopilotHomeVolume` | empty | Copilot GitHub mode: wslc volume for `/home/agent/.copilot`, so a sign-in survives sessions (holds a credential) |
| `-StrictDns` | off | Fail the self-test if external DNS resolves |
| `-ProxyStartTimeoutSec` | `30` | Readiness timeout for the proxies |
| `-Monitor` | off | Start the egress monitor and web UI |
| `-MonitorPort` / `-MonitorBind` | `8081` / `127.0.0.1` | Host port and bind address of the monitor UI. Binding is restricted to `127.0.0.1` because the UI has no authentication; the port is checked before containers start |
| `-MonitorImage` | `agent-egress-monitor:local` | Monitor image |
| `-NoBrowser` | off | Do not open the monitor in the browser |

## Environment variables

### Agent container (set by the launcher)

| Variable | Value | Description |
|---|---|---|
| `OLLAMA_API_KEY` | `proxy-injected`, or the real key with `-NoKeyInjection`; not set in GitHub mode | Placeholder under injection |
| `OLLAMA_BASE_URL` | `http://oc-api-<session>:8080/v1` with injection | Model endpoint |
| `OLLAMA_MODELS` | `-Models` | Model list |
| `OPENCODE_AUTO` | `1` / `0` | Auto mode for either agent |
| `AGENT_RUN_AS_ROOT` | `1` with `-RunAsRoot` | Agent phase runs as root with a minimal capability set instead of as `agent` |
| `COPILOT_WIRE_API` | `-CopilotWireApi` | BYOK: mapped to `COPILOT_PROVIDER_WIRE_API` |
| `COPILOT_AUTH` | `github` with `-CopilotAuth github` | Selects the Copilot auth branch in the entrypoint; default `byok` |
| `COPILOT_GITHUB_TOKEN` | host env or vault, by name | GitHub mode only; unset in BYOK mode |
| `COPILOT_NODE_OPTIONS` | `-CopilotNodeOptions` | Copilot: becomes `NODE_OPTIONS` unless one is set explicitly; `UV_THREADPOOL_SIZE` defaults to 16 |
| `COPILOT_MODEL` | `-CopilotModel` | GitHub mode only; BYOK sets it from `-Models` |
| `OPENCODE_CONFIG` | `/run/agent-mcp.json` with `-McpConfig` | OpenCode custom config layer mounted read-only and merged with the generated global provider config |
| `EXTRA_APK_PACKAGES` | `-ApkPackages` | Installed as root before the privilege drop |
| `EGRESS_MODE` | `proxy` | `proxy` = run the isolation self-test (fail closed); `none` = skip it (explicit opt-out) |
| `HTTPS_PROXY`, `HTTP_PROXY` (+ lowercase) | `http://oc-proxy-<session>:3128` | Squid |
| `NO_PROXY` (+ lowercase) | `localhost,127.0.0.1,oc-api-<session>` | API proxy is reached directly |
| `PROXY_CHECK_DOMAIN` | first exact allowlisted domain, or empty | Self-test; empty skips the allowlist check |
| `PROXY_ALLOW_ALL` | `-AllowAllDomains` | Self-test: verifies `example.com` works **through** squid instead of being denied |
| `PROXY_ALLOW_HTTP` | `-AllowHttp` | Allow and verify plain HTTP on port 80 |
| `API_PROXY_URL`, `API_KEY_PLACEHOLDER` | with injection | Self-test: API proxy reachable, real key absent |
| `STRICT_DNS` | `-StrictDns` | `1` = fail on external DNS resolution |

### API proxy container

| Variable | Description |
|---|---|
| `OLLAMA_API_KEY` | The real key, by name only; removed from the process environment after start |
| `API_UPSTREAM` | Upstream base URL, HTTPS only (default `https://ollama.com`) |
| `API_PROXY_ALLOWED_PATHS` | Path prefixes (default `/v1/`) |
| `API_PROXY_MODELS` | Model allowlist (set from `-Models` unless `-AnyModel`) |
| `API_PROXY_MAX_REQUESTS` | Request cap, `0` = none |
| `API_PROXY_FORCE_STREAM_USAGE` | `1` = request usage in streaming chat completions (set by `-ForceStreamUsage`) |
| `API_PROXY_MAX_BODY`, `API_PROXY_TIMEOUT` | Body limit (32 MB) and upstream timeout (600 s) |
| `VIEWER_LOG_TARGET` | Monitor UDP target, with `-Monitor` |

### Squid container

| Variable | Description |
|---|---|
| `PROXY_ALLOW_DOMAINS` | Allowlist; may be empty (all `CONNECT` requests denied) |
| `PROXY_HOSTNAME` | Squid `visible_hostname`, set to the container name |
| `PROXY_ALLOW_ALL` | `1` = allow `CONNECT :443` to any domain (set by `-AllowAllDomains`) |
| `PROXY_ALLOW_HTTP` | `1` = also allow plain HTTP :80 to allowed domains (set by `-AllowHttp`) |
| `PROXY_DENY_DOMAINS` | Always denied, evaluated before the allowlist and allow-all; the launcher sets `ollama.com` in allow-all mode with injection |
| `API_PROXY_HOST` | With injection: plain HTTP to this host on port 8080 is forwarded |
| `PROXY_PARENT_HOST` | Tor mode: mandatory Privoxy parent on port 8118; enables `never_direct allow all` |
| `MGR_PASSWORD`, `VIEWER_LOG_TARGET` | With `-Monitor`: cache manager password and UDP log target |

## Workspace options

By default every session gets a new folder under `-SessionRoot`. Instead, `/workspace` can be an existing folder or an existing wslc volume.

| Option | Mount | Persists | Visible in Windows Explorer |
|---|---|---|---|
| default | new `<SessionRoot>\<Session>` folder | yes, reuse with `-Session` | yes |
| `-Workspace C:\src\repo` | existing host folder (must exist) | yes, it is your folder | yes |
| `-Workspace my-volume` | existing wslc volume (`wslc volume create my-volume`) | yes, until `wslc volume rm` | no; access it through a container |
| `-WorkspaceReadOnly` | adds `:ro` to any of the above | n/a | n/a |

Resolution order for `-Workspace`: an existing folder wins over a volume with the same name. A name that is neither fails before anything starts.

**Risks with existing folders:**
- **Host code execution later.** In a git repository mounted read-write, the agent can change `.git/hooks`, `.vscode/tasks.json`, build scripts or `package.json` scripts, which run on your host the next time you use git or the IDE there. The launcher warns. Prefer `-WorkspaceReadOnly` for review tasks, or a `git worktree` copy for changes, and review diffs before running anything on the host.
- **Concurrent sessions.** Two sessions on the same folder or volume can overwrite each other's changes. Use one session per workspace.
- **Permissions.** Files the agent creates are owned by UID 1000. An existing volume owned by another UID may not be writable; the entrypoint warns and never changes ownership of your data.

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

See [SECURITY.md](SECURITY.md) for the repository's threat model, supported security scope,
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
