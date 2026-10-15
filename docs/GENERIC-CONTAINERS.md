# Restricted custom containers

[← Main README](../README.md) · [Operations guide](OPERATIONS.md) · [Security policy](../SECURITY.md)

`Start-RestrictedContainer.ps1` runs an arbitrary image with the repository's Squid allowlist,
optional live monitor, and optional Tor gateway. It does not start an AI agent or API-key proxy.

## Build the sidecars

Build the proxy and the generic Alpine example. Add the monitor and Tor gateway when needed:

```powershell
.\Build-AgentImages.ps1 -Images proxy,generic-alpine
.\Build-AgentImages.ps1 -Images proxy,monitor,generic-alpine
.\Build-AgentImages.ps1 -Images proxy,monitor,tor-gateway,generic-alpine
```

The historical builder name is retained for compatibility. `generic-alpine` is an ordinary example
workload discovered from its folder; it is not a hard-coded launcher dependency.

Any new root-level folder containing a `Dockerfile` is discovered automatically by the builder's
default `-Images all` mode. It can also be built directly, without editing the script:

```powershell
# ./my-container/Dockerfile
.\Build-AgentImages.ps1 -Images my-container
.\Start-RestrictedContainer.ps1 -Image my-container:local -Shell
```

For ordinary custom folders, the generated tag is the lowercase folder name plus `:local`.
Renaming `generic-alpine` to `alpine2` therefore only changes the selected folder and image tag:

```powershell
.\Build-AgentImages.ps1 -Images proxy,monitor,alpine2
.\Start-RestrictedContainer.ps1 -Image alpine2:local -Shell -Monitor
```

## Start a workload

Egress is deny-all when no domains are supplied:

```powershell
.\Start-RestrictedContainer.ps1 -Image alpine:3.22
```

Allow a selected HTTPS destination and show the live monitor:

```powershell
.\Start-RestrictedContainer.ps1 `
  -Image alpine:3.22 `
  -Shell `
  -AllowDomains example.com `
  -Monitor
```

`-Shell` starts the image in the background and enters `/bin/sh` with `wslc exec -it`. Exiting the
shell tears down the workload and sidecars. Use `-ShellPath` for another shell.

Inside the Alpine shell, the allowlisted request succeeds, an unlisted destination is denied, and
clearing the proxy variables does not create a direct route:

```sh
wget -qO- https://example.com
wget -qO- https://example.net                                      # denied by Squid
HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= wget -qO- https://example.com  # no route
```

Without `-Shell`, everything after `--` is passed to the image as its command. With no command, the
image's default command is used. Its normal entrypoint is preserved unless `-Entrypoint` is supplied:

```powershell
.\Start-RestrictedContainer.ps1 -Image alpine:3.22 -AllowDomains example.com -- wget -qO- https://example.com
```

The launcher creates an internal network, starts the sidecars, and then starts the workload. There
is no additional helper or startup script inside the workload image.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Image` | required | Workload image tag or digest |
| `-Session` | timestamped | Names the workload, sidecars, networks, and logs |
| `-SessionRoot` | `C:\temp\wslc-container-sessions` | Parent of `_proxy-logs` |
| `-AllowDomains` | empty | Exact hosts or leading-dot domains allowed over HTTPS :443 |
| `-DenyDomains` | empty | Hosts always denied; evaluated before allow and allow-all rules |
| `-AllowAllDomains` | off | Allow HTTPS :443 to any domain for short discovery runs |
| `-AllowHttp` | off | Also permit plain HTTP :80 under the same destination policy |
| `-Environment` | empty | Literal `NAME=value` variables passed to the workload |
| `-PassEnvironment` | empty | Names of existing host variables passed by name |
| `-Volume` | empty | Raw `source:destination[:ro]` volume specifications |
| `-Publish` | empty | TCP mappings in required `127.0.0.1:host:container` form |
| `-Entrypoint` | image default | Override the image entrypoint |
| `-Memory` / `-Cpus` | `4g` / `2` | Workload resource limits |
| `-NoTty` | off | Do not allocate an interactive terminal |
| `-Shell` / `-ShellPath` | off / `/bin/sh` | Keep the image running and enter an interactive shell |
| `-RunAsRoot` | off | Run as UID 0 and add `dl-cdn.alpinelinux.org` so Alpine `apk` can download packages |
| `-Monitor` | off | Start the localhost-only egress UI |
| `-MonitorPort` | `8081` | Local monitor port |
| `-Tor` | off | Force Squid upstream traffic through the Tor gateway |

Both upper- and lowercase `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` variables are controlled by
the launcher and cannot be overridden through `-Environment` or `-PassEnvironment`.

The minimal `generic-alpine` example already defaults to root because its base image declares no
non-root `USER`, but deny-all egress still prevents `apk` downloads. Use `-RunAsRoot` when you want
an Alpine shell with package installation: it explicitly runs as UID 0 and adds only the Alpine CDN
to the HTTPS allowlist. It does not grant additional container capabilities.

```powershell
.\Start-RestrictedContainer.ps1 -Image generic-alpine:local -Shell -RunAsRoot -Monitor
```

Inside the shell:

```sh
apk add --no-cache curl jq
```

The default Alpine repositories use HTTPS, so this `apk add` workflow does not require
`-AllowHttp`. If you intentionally configure an HTTP-only package mirror or need another
allowlisted HTTP endpoint, opt in explicitly:

```powershell
.\Start-RestrictedContainer.ps1 `
  -Image generic-alpine:local `
  -Shell `
  -RunAsRoot `
  -AllowHttp `
  -Monitor
```

`-AllowHttp` opens port 80 only under the same destination policy; it does not allow arbitrary
domains. Add any non-Alpine mirror hostname with `-AllowDomains`, for example
`-AllowDomains packages.example.com`. Prefer HTTPS because HTTP traffic can be observed or changed
in transit.

## Environment, volumes, and ports

```powershell
$env:APP_TOKEN = Get-Secret -Name AppToken -AsPlainText

.\Start-RestrictedContainer.ps1 `
  -Image my-app@sha256:<digest> `
  -AllowDomains api.example.com `
  -Environment 'APP_MODE=test','LOG_LEVEL=info' `
  -PassEnvironment APP_TOKEN `
  -Volume 'C:\input:/input:ro','app-state:/state' `
  -Publish '127.0.0.1:8080:8080'
```

`-PassEnvironment` avoids putting a secret value in the launcher command line, but the variable is
still present inside the workload and visible to anyone who can inspect containers as the same host
user. Published ports are intentionally limited to IPv4 localhost because the workload is not
assumed to provide authentication.

## Discover and restrict destinations

Use allow-all only for a short discovery run:

```powershell
.\Start-RestrictedContainer.ps1 -Image my-app:local -AllowAllDomains -Monitor
```

Observe the destinations, stop the workload, and restart with an explicit list:

```powershell
.\Start-RestrictedContainer.ps1 `
  -Image my-app:local `
  -AllowDomains api.example.com,cdn.example.com `
  -Monitor
```

Allow-all retains the internal network and proxy routing but removes destination restriction. It is
an observation mode, not a hardened operating mode.

## Proxy compatibility

The launcher supplies conventional uppercase and lowercase HTTP proxy variables. Applications that
support an HTTP forward proxy can use HTTPS `CONNECT` through Squid. An application that ignores
these variables, uses a non-HTTP protocol, or attempts a direct socket has no external route and
fails closed. SSH, UDP, arbitrary TCP ports, and `git@...` SSH URLs are not supported.

An allowed destination can still receive any data accessible to the workload. Squid observes the
destination and connection metadata but does not decrypt TLS.

## Tor

`-Tor` retains the domain policy and changes only Squid's upstream path:

```text
workload ── internal network ── Squid ── internal transit ── Privoxy/Tor ── destination
```

Use Tor only after reviewing [the Tor guidance](../TOR.md). It hides the source network, not account
identity or request content, and may introduce blocks, challenges, or substantial latency.

## Cleanup and logs

The workload or interactive shell controls the launcher lifetime. When it exits or the launcher is
interrupted, the launcher stops resources it created and removes its networks. It refuses existing
container or network names instead of taking ownership of them. Squid and Tor logs are retained below
`<SessionRoot>\_proxy-logs`; the monitor's UDP view remains best-effort.

The workload exit code is returned after cleanup. Use a unique `-Session` for concurrent runs.

## Security boundary

This launcher controls network topology; it does not harden the internals of an arbitrary image.
It does not change the image's user, capabilities, filesystem, entrypoint, or secret handling.
Trust the image and WSLc runtime, pin important images by digest, use read-only mounts, and keep
destination lists narrow. Unlike the agent image, a generic workload does not run a launch-time
route or DNS self-test.
