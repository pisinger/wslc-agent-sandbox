# Configuration reference

[← Main README](../README.md) · [Operations guide](OPERATIONS.md) · [Security policy](../SECURITY.md)

Use this guide for agent modes, credentials, launcher options, environment variables, and workspace mounts. Commands and paths are relative to the repository root unless stated otherwise.

## Contents

- [Agents](#agents)
- [API key injection](#api-key-injection)
- [Running without key injection](#running-without-key-injection--nokeyinjection)
- [Launcher parameters](#launcher-parameters)
- [Environment variables](#environment-variables)
- [Workspace options](#workspace-options)

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

`yamllint` pulls in Python 3 as a dependency, so `python3` is available too (use a virtual environment for `pip`; see [Python work](OPERATIONS.md#python-work)). Additional tools per session: `-ApkPackages`; permanently: add them to `agent/Dockerfile`.

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
| `-RunAsRoot` | off | Run the agent CLI as root, so it can install tools with `apk` itself. Same image; `dl-cdn.alpinelinux.org` is added to the allowlist. See [Agent as root](OPERATIONS.md#agent-as-root--runasroot) |
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

