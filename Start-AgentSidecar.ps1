<#
.SYNOPSIS
  Isolated agent session (opencode or GitHub Copilot CLI) on WSL containers.
.DESCRIPTION
  The agent runs on an internal wslc network with no route out. Egress goes through a squid
  allowlist proxy. By default the model API key is held only by a separate API proxy that
  injects it into requests; the agent container receives a placeholder.
  -Monitor adds a live egress monitor (web UI on http://localhost:<MonitorPort>).
  Everything is torn down on exit; logs are saved to <SessionRoot>\_proxy-logs.
.EXAMPLE
  .\Start-AgentSidecar.ps1
  .\Start-AgentSidecar.ps1 -Agent copilot -Monitor
  .\Start-AgentSidecar.ps1 -Agent copilot -Models "glm-5.1" -CopilotWireApi completions
  .\Start-AgentSidecar.ps1 -Agent copilot -CopilotAuth github                      # GitHub models, /login
  .\Start-AgentSidecar.ps1 -Agent copilot -CopilotAuth github -CopilotHomeVolume copilot-home
  .\Start-AgentSidecar.ps1 -Agent copilot -Workspace C:\src\myrepo -WorkspaceReadOnly
  .\Start-AgentSidecar.ps1 -Workspace my-agent-volume
  .\Start-AgentSidecar.ps1 -Tor -Monitor
  .\Start-AgentSidecar.ps1 -NoKeyInjection -AllowDomains "ollama.com registry.npmjs.org models.dev"
#>
param(
    [string]$SessionRoot   = "C:\temp\wslc-agent-sessions",
    [string]$Session       = "oc-$(Get-Date -Format yyyyMMdd-HHmmss)",
    [string]$Workspace     = "",
    [switch]$WorkspaceReadOnly,
	
    [ValidateSet("opencode", "copilot")]
	[string]$Agent 		   = "opencode",
    [string]$Models        = "deepseek-v4.1-flash",
    [string]$McpConfig     = "",
	
    [string]$Image         = "",
    [string]$ProxyImage    = "agent-egress-proxy:local",
    [string]$ApiProxyImage = "agent-api-proxy:local",
    [switch]$Tor,
    [string]$TorImage      = "agent-tor-gateway:local",
    [int]$TorStartTimeoutSec = 60,
	
    [string[]]$AllowDomains = @(),
    [switch]$AllowAllDomains,
    [switch]$AllowHttp,
    [string]$ApkPackages   = "",
    [switch]$NoAuto,
	
    [switch]$RunAsRoot,
    [switch]$NoKeyInjection,
    [switch]$AnyModel,
    [int]$MaxModelRequests = 0,
    [switch]$ForceStreamUsage,
	
    [ValidateSet("completions", "responses")][string]
	$CopilotWireApi = "responses",
	
    [ValidateSet("byok", "github")]
	[string]$CopilotAuth = "byok",
	
    [string]$CopilotModel = "",
    [string]$CopilotHomeVolume = "",
    [string]$CopilotNodeOptions = "--max-old-space-size=3072 --max-semi-space-size=64",
	
    [switch]$StrictDns,
    [int]$ProxyStartTimeoutSec = 30,
    [switch]$Monitor,
    [int]$MonitorPort = 8081,
    [string]$MonitorBind = "127.0.0.1",
    [string]$MonitorImage = "agent-egress-monitor:local",
    [switch]$NoBrowser
)
# Native wslc errors are checked via $LASTEXITCODE (Stop + 2>&1 misbehaves in Windows PowerShell 5.1).
function Assert-Wslc([string]$Step) { if ($LASTEXITCODE -ne 0) { throw "wslc failed: $Step (exit $LASTEXITCODE)" } }
# Workspace: new session folder (default), an existing host folder, or an existing wslc volume.
function Resolve-Workspace([string]$Workspace, [string]$SessionFolder, [bool]$ReadOnly) {
    $ro = if ($ReadOnly) { ":ro" } else { "" }
    if (-not $Workspace) {
        New-Item -ItemType Directory -Path $SessionFolder -Force | Out-Null
        return @{ Mount = "${SessionFolder}:/workspace$ro"; Info = "session folder $SessionFolder"; Folder = $SessionFolder }
    }
    if (Test-Path -LiteralPath $Workspace -PathType Container) {
        $full = (Resolve-Path -LiteralPath $Workspace).Path
        if (-not $ReadOnly -and (Test-Path -LiteralPath (Join-Path $full '.git'))) {
            Write-Warning ("Workspace is a git repository mounted read-write. The agent can change .git/hooks, " +
                           ".vscode tasks or scripts that later run on your host. Review changes before using git/IDE there, " +
                           "or use -WorkspaceReadOnly / a worktree copy.")
        }
        return @{ Mount = "${full}:/workspace$ro"; Info = "existing folder $full"; Folder = $full }
    }
    if ($Workspace -match '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
        wslc volume inspect $Workspace *> $null
        if ($LASTEXITCODE -eq 0) {
            return @{ Mount = "${Workspace}:/workspace$ro"; Info = "volume $Workspace"; Folder = $null }
        }
    }
    throw "Workspace '$Workspace' is neither an existing folder nor an existing wslc volume (create one with 'wslc volume create <name>')."
}
function Wait-ContainerLog([string]$Container, [string]$Pattern, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not ((wslc container logs $Container 2>&1) -match $Pattern)) {
        if ((Get-Date) -gt $deadline) {
            wslc container logs $Container 2>&1 | Write-Host
            throw "$Container did not become ready within $TimeoutSec s"
        }
        Start-Sleep -Milliseconds 500
    }
}
function Test-TcpPortAvailable([string]$BindAddress, [int]$Port) {
    $listener = $null
    try {
        $address = [Net.IPAddress]::Parse($BindAddress)
        $listener = [Net.Sockets.TcpListener]::new($address, $Port)
        $listener.Start()
        return $true
    }
    catch { return $false }
    finally { if ($listener) { $listener.Stop() } }
}
# Health probe that never uses the Windows/WinINet system proxy: Invoke-WebRequest may send
# localhost requests to a corporate proxy, which cannot reach the published container port.
function Test-HttpOk([string]$Url, [int]$TimeoutMs = 2000) {
    $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Proxy = $null
        $req.Timeout = $TimeoutMs
        $resp = $req.GetResponse()
        return ([int]$resp.StatusCode -eq 200)
    }
    catch { $script:LastHealthError = $_.Exception.InnerException.Message; if (-not $script:LastHealthError) { $script:LastHealthError = $_.Exception.Message }; return $false }
    finally { if ($resp) { $resp.Close() } }
}

$GitHubMode = ($Agent -eq "copilot" -and $CopilotAuth -eq "github")
if ($Tor -and $GitHubMode) { throw "-Tor cannot be combined with -Agent copilot -CopilotAuth github. Use Copilot BYOK, or start without -Tor." }
if ($Tor -and $NoKeyInjection) { throw "-Tor cannot be combined with -NoKeyInjection because model API traffic must stay on the direct API-proxy path." }
if ($TorStartTimeoutSec -lt 1) { throw "-TorStartTimeoutSec must be at least 1 second." }
if ($Monitor) {
    if ($MonitorBind -ne "127.0.0.1") {
        throw "-MonitorBind must be 127.0.0.1. The monitor has no authentication and may not be exposed beyond localhost."
    }
    if ($MonitorPort -lt 1 -or $MonitorPort -gt 65535) { throw "-MonitorPort must be between 1 and 65535." }
    if (-not (Test-TcpPortAvailable $MonitorBind $MonitorPort)) {
        throw "Monitor port ${MonitorBind}:$MonitorPort is already in use. Stop the listener or choose another port with -MonitorPort."
    }
}
if ($GitHubMode -and $NoKeyInjection) { Write-Warning "-NoKeyInjection has no effect with -CopilotAuth github (no Ollama key is used)." }
if (-not $GitHubMode -and ($CopilotModel -or $CopilotHomeVolume)) { Write-Warning "-CopilotModel / -CopilotHomeVolume only apply to -Agent copilot -CopilotAuth github." }
# The API key injection proxy only serves the Ollama API; GitHub mode talks to GitHub directly via squid.
$Inject = -not $NoKeyInjection -and -not $GitHubMode
if ($Session -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw "Invalid session name: $Session" }
$Name       = $Session.ToLower()
$NetName    = "oc-int-$Name"
$ProxyName  = "oc-proxy-$Name"
$ApiName    = "oc-api-$Name"
$MonNet     = "oc-mon-$Name"
$ViewerName = "oc-monitor-$Name"
$TorNet     = "oc-tor-$Name"
$TorName    = "oc-tor-gateway-$Name"
$Placeholder = "proxy-injected"
if (-not $Image) { $Image = if ($Agent -eq "copilot") { "copilot-alpine:local" } else { "opencode-alpine:local" } }

# MCP clients discover their tools at startup. Validate and mount an agent-native config before
# launching the CLI rather than relying on a live reload inside the interactive session.
$McpConfigResolved = ""
if ($McpConfig) {
    if (-not (Test-Path -LiteralPath $McpConfig -PathType Leaf)) {
        throw "MCP config '$McpConfig' is not an existing file."
    }
    $McpConfigResolved = (Resolve-Path -LiteralPath $McpConfig).Path
    try { $mcpJson = Get-Content -LiteralPath $McpConfigResolved -Raw | ConvertFrom-Json }
    catch { throw "MCP config '$McpConfig' is not valid JSON: $($_.Exception.Message)" }
    if ($Agent -eq "opencode" -and -not ($mcpJson.PSObject.Properties.Name -contains 'mcp')) {
        throw "OpenCode MCP config must contain a top-level 'mcp' object."
    }
    if ($Agent -eq "copilot" -and -not ($mcpJson.PSObject.Properties.Name -contains 'mcpServers')) {
        throw "Copilot MCP config must contain a top-level 'mcpServers' object."
    }
}

# Default allowlist per agent and key mode. With injection the model API is reached via the
# API proxy, so ollama.com must NOT be reachable for the agent through squid.
if (-not $PSBoundParameters.ContainsKey('AllowDomains')) {
    $AllowDomains = if ($GitHubMode) {
        # Copilot allowlist reference: auth, user/entitlement API, Copilot API and suggestion proxies.
        "github.com api.github.com .githubcopilot.com copilot-proxy.githubusercontent.com origin-tracker.githubusercontent.com"
    } else { switch ("$Agent/$Inject") {
        "opencode/True"  { "models.dev registry.npmjs.org" }
        "opencode/False" { "ollama.com registry.npmjs.org models.dev" }
        "copilot/True"   { "" }
        "copilot/False"  { "ollama.com" }
    } }
}
if ($AllowAllDomains -and $PSBoundParameters.ContainsKey('AllowDomains')) {
    Write-Warning "-AllowDomains is ignored with -AllowAllDomains."
}
if ($AllowDomains) {
    # Accept idiomatic PowerShell arrays (`a.com, b.com`) and quoted space-separated input.
    $AllowDomains = (($AllowDomains -join ' ') -split '[,\s]+' | Where-Object { $_ }) -join ' '
}
if (-not $AllowAllDomains -and $AllowDomains) {
    foreach ($domain in ($AllowDomains -split '\s+' | Where-Object { $_ })) {
        if ($domain -notmatch '^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') {
            throw "Invalid domain '$domain' in -AllowDomains. Use hostnames only, separated by commas or spaces."
        }
    }
}
if ($Inject -and ($AllowDomains -split '\s+') -match '^\.?ollama\.com$') {
    throw "With API key injection, ollama.com must not be in -AllowDomains (the agent would bypass the API proxy)."
}
# Root agent can install packages itself, so the Alpine CDN must be reachable.
if (($ApkPackages -or $RunAsRoot) -and $AllowDomains -notmatch 'dl-cdn\.alpinelinux\.org') {
    $AllowDomains = "$AllowDomains dl-cdn.alpinelinux.org".Trim()
}
$LogDir = Join-Path $SessionRoot '_proxy-logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Ws = Resolve-Workspace $Workspace (Join-Path $SessionRoot $Session) ([bool]$WorkspaceReadOnly)

# Prerequisite: internal networks. Without them the agent would have a direct route out.
$netHelp = (wslc network create --help 2>&1) -join "`n"
if ($netHelp -notmatch '--internal') {
    throw "This wslc build has no 'network create --internal'. The agent cannot be isolated; update WSL."
}

# GitHub mode: optional token (env > vault "CopilotGithubToken"); without one the user runs /login.
$GitHubTokenSet = $false
if ($GitHubMode) {
    if (-not $env:COPILOT_GITHUB_TOKEN -and (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        $env:COPILOT_GITHUB_TOKEN = Get-Secret -Name CopilotGithubToken -AsPlainText -ErrorAction SilentlyContinue
        $GitHubTokenSet = [bool]$env:COPILOT_GITHUB_TOKEN
    }
    if ($CopilotHomeVolume) {
        wslc volume inspect $CopilotHomeVolume *> $null
        if ($LASTEXITCODE -ne 0) { wslc volume create $CopilotHomeVolume | Out-Null; Assert-Wslc "volume create $CopilotHomeVolume" }
    }
}

# Ollama key (not needed in GitHub mode). Order: existing process env > SecretManagement vault > prompt.
if (-not $GitHubMode -and -not $env:OLLAMA_API_KEY) {
    if (Get-Command Get-Secret -ErrorAction SilentlyContinue) {
        #$env:OLLAMA_API_KEY = Get-Secret -Name OllamaApiKey -AsPlainText -ErrorAction SilentlyContinue
		$env:OLLAMA_API_KEY = PasswordFromPsVault -SecretName ollamaApiKey -noClipboard
    }
    if (-not $env:OLLAMA_API_KEY) {
        $sec = Read-Host "OLLAMA_API_KEY" -AsSecureString
        $env:OLLAMA_API_KEY = [Net.NetworkCredential]::new('', $sec).Password
    }
}

$ProxyUrl = "http://${ProxyName}:3128"
$ApiUrl   = "http://${ApiName}:8080"
$NoProxy  = if ($Inject) { "localhost,127.0.0.1,$ApiName" } else { "localhost,127.0.0.1" }
$CheckDomain = ($AllowDomains -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('.') } | Select-Object -First 1)

# Only non-secret values here; they are passed as NAME=value. The real key is passed by name only.
$monitorEnv = @{}
if ($Monitor) {
    # Per-session cache manager password, shared only by proxy and monitor (CSPRNG, rejection sampling).
    $chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $pw = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 64
    while ($pw.Length -lt 32) {
        $rng.GetBytes($buf)
        foreach ($b in $buf) { if ($b -lt 248 -and $pw.Length -lt 32) { [void]$pw.Append($chars[$b % 62]) } }
    }
    # Passed by name (it is a credential), so it goes through the process environment.
    $env:MGR_PASSWORD = $pw.ToString()
}

try {
    $mode = if ($GitHubMode) { "GitHub auth" } else { "key injection: $Inject" }
    if ($RunAsRoot) { Write-Warning "Agent runs as ROOT inside its container (-RunAsRoot): it can install packages with apk and modify the container." }
    Write-Host "Session '$Name' ($Agent, $mode) -> $($Ws.Info)$(if ($WorkspaceReadOnly) { ' (read-only)' })"
    wslc network create --internal $NetName | Out-Null; Assert-Wslc "network create"

    $TorExitIp = ""
    if ($Tor) {
        wslc network create --internal $TorNet | Out-Null; Assert-Wslc "Tor transit network create"
        wslc run -d --name $TorName --memory 256m --cpus 0.5 $TorImage | Out-Null; Assert-Wslc "Tor gateway run"
        wslc network connect $TorNet $TorName; Assert-Wslc "Tor gateway network connect"
        Wait-ContainerLog $TorName 'tor-gateway: ready exit_ip=' $TorStartTimeoutSec
        $torLogs = (wslc container logs $TorName 2>&1) -join "`n"
        $TorExitIp = [regex]::Match($torLogs, 'tor-gateway: ready exit_ip=([^\s]+)').Groups[1].Value
        if (-not $TorExitIp) { throw "Tor gateway reported ready without a verified exit IP" }
        Write-Host "Tor gateway ready: verified exit $TorExitIp"
        if ($AllowHttp) { Write-Warning "Plain HTTP through Tor can be read and modified by the exit relay." }
    }

    $egressNet = @()
    $logTarget = @()
    if ($Monitor) {
        # In Tor mode the monitor starts on the normal network so host port publishing works, then
        # also joins the internal Tor transit network to receive logs and reach Squid. Squid never
        # joins the monitor's normal network, so it still has no direct-egress interface.
        if (-not $Tor) {
            wslc network create $MonNet | Out-Null; Assert-Wslc "monitor network create"
            $monitorRunNet = @('--network', $MonNet)
        } else {
            $monitorRunNet = @()
        }
        $publish = if ($MonitorBind) { "${MonitorBind}:${MonitorPort}:8080" } else { "${MonitorPort}:8080" }
        wslc run -d --name $ViewerName @monitorRunNet -p $publish `
            -e MGR_PASSWORD `
            -e "PROXY_MGR_URL=http://${ProxyName}:3128/squid-internal-mgr/active_requests" `
            -e "SESSION_NAME=$Name" `
            -e "TOR_MODE=$(if ($Tor) { '1' } else { '0' })" `
            -e "TOR_EXIT_IP=$TorExitIp" `
            --memory 256m --cpus 0.5 $MonitorImage | Out-Null; Assert-Wslc "monitor run"
        if ($Tor) { wslc network connect $TorNet $ViewerName; Assert-Wslc "monitor Tor network connect" }
        if (-not $Tor) { $egressNet = @('--network', $MonNet) }
        $logTarget = @('-e', "VIEWER_LOG_TARGET=${ViewerName}:5140")
    }

    # API proxy: egress network + internal network. The ONLY container that holds the real key.
    if ($Inject) {
        $modelArgs = if ($AnyModel) { @() } else { @('-e', "API_PROXY_MODELS=$Models") }
        $apiNet = if ($Tor) { @() } else { $egressNet }
        wslc run -d --name $ApiName @apiNet `
            -e OLLAMA_API_KEY `
            -e "API_PROXY_MAX_REQUESTS=$MaxModelRequests" `
            -e "API_PROXY_FORCE_STREAM_USAGE=$(if ($ForceStreamUsage) { '1' } else { '0' })" `
            @modelArgs @logTarget `
            --memory 256m --cpus 0.5 $ApiProxyImage | Out-Null; Assert-Wslc "api proxy run"
        if ($Tor -and $Monitor) { wslc network connect $TorNet $ApiName; Assert-Wslc "api proxy monitor network connect" }
        wslc network connect $NetName $ApiName; Assert-Wslc "api proxy network connect"
        Wait-ContainerLog $ApiName 'api-proxy: :8080' $ProxyStartTimeoutSec
        Write-Host "API proxy ready: $ApiUrl (models: $(if ($AnyModel) { 'any' } else { $Models }), cap: $(if ($MaxModelRequests) { $MaxModelRequests } else { 'none' }))"
    }

    # Squid: egress network + internal network.
    $squidArgs = @('-e', "PROXY_ALLOW_DOMAINS=$AllowDomains", '-e', "PROXY_HOSTNAME=$ProxyName",
                   '-e', "PROXY_ALLOW_HTTP=$(if ($AllowHttp) { '1' } else { '0' })") + $logTarget
    if ($AllowAllDomains) {
        $squidArgs += @('-e', 'PROXY_ALLOW_ALL=1')
        # Keep the injection guarantee: the model API stays reachable only via the API proxy.
        if ($Inject) { $squidArgs += @('-e', 'PROXY_DENY_DOMAINS=ollama.com') }
    }
    if ($Monitor) { $squidArgs += @('-e', 'MGR_PASSWORD') }
    if ($Inject)  { $squidArgs += @('-e', "API_PROXY_HOST=$ApiName") }
    if ($Tor)     { $squidArgs += @('-e', "PROXY_PARENT_HOST=$TorName") }
    $squidNet = if ($Tor) { @('--network', $TorNet) } else { $egressNet }
    wslc run -d --name $ProxyName @squidNet @squidArgs --memory 256m --cpus 0.5 $ProxyImage | Out-Null; Assert-Wslc "proxy run"
    wslc network connect $NetName $ProxyName; Assert-Wslc "network connect"
    Wait-ContainerLog $ProxyName 'Accepting HTTP Socket connections' $ProxyStartTimeoutSec
    $ports = if ($AllowHttp) { ':443 HTTPS + :80 HTTP' } else { ':443 HTTPS only' }
    Write-Host "Egress proxy ready, allowlist: $(if ($AllowAllDomains) { "ALL domains ($ports, logged)" } elseif ($AllowDomains) { "$AllowDomains ($ports)" } else { '(empty)' })"

    if ($Monitor) {
        $url = "http://localhost:$MonitorPort/"
        # Probe the bind address directly: "localhost" may resolve to ::1 first, the port is published on IPv4.
        $probe = "http://${MonitorBind}:$MonitorPort/healthz"
        $ok = $false
        for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
            $ok = Test-HttpOk $probe
            if (-not $ok) { Start-Sleep -Milliseconds 500 }
        }
        if ($ok) { Write-Host "Egress monitor: $url" }
        else { Write-Warning "Monitor health check on $probe failed ($script:LastHealthError); check 'wslc container logs $ViewerName'. Opening it anyway, session continues." }
        # The container is running either way; a page that loads a moment later beats no page.
        if (-not $NoBrowser) { Start-Process $url }
    }

    # Agent: internal network only, no extra capabilities.
    # Windows env vars are case-insensitive, so upper- and lowercase proxy vars are passed as NAME=value.
    $agentArgs = @(
        '-e', "OLLAMA_MODELS=$Models",
        '-e', "OPENCODE_AUTO=$(if ($NoAuto) { '0' } else { '1' })",
        '-e', "AGENT_RUN_AS_ROOT=$(if ($RunAsRoot) { '1' } else { '0' })",
        '-e', "COPILOT_WIRE_API=$CopilotWireApi",
        '-e', "COPILOT_NODE_OPTIONS=$CopilotNodeOptions",
        '-e', "EXTRA_APK_PACKAGES=$ApkPackages",
        '-e', 'EGRESS_MODE=proxy',
        '-e', "PROXY_CHECK_DOMAIN=$CheckDomain",
        '-e', "PROXY_ALLOW_ALL=$(if ($AllowAllDomains) { '1' } else { '0' })",
        '-e', "PROXY_ALLOW_HTTP=$(if ($AllowHttp) { '1' } else { '0' })",
        '-e', "STRICT_DNS=$(if ($StrictDns) { '1' } else { '0' })",
        '-e', "HTTPS_PROXY=$ProxyUrl", '-e', "HTTP_PROXY=$ProxyUrl", '-e', "NO_PROXY=$NoProxy",
        '-e', "https_proxy=$ProxyUrl", '-e', "http_proxy=$ProxyUrl", '-e', "no_proxy=$NoProxy",
        '-v', $Ws.Mount
    )
    if ($GitHubMode) {
        $agentArgs += @('-e', 'COPILOT_AUTH=github')
        if ($env:COPILOT_GITHUB_TOKEN) { $agentArgs += @('-e', 'COPILOT_GITHUB_TOKEN') }   # by name only
        if ($CopilotModel)            { $agentArgs += @('-e', "COPILOT_MODEL=$CopilotModel") }
        if ($CopilotHomeVolume)       { $agentArgs += @('-v', "${CopilotHomeVolume}:/home/agent/.copilot") }
    } elseif ($Inject) {
        $agentArgs += @('-e', "OLLAMA_API_KEY=$Placeholder", '-e', "OLLAMA_BASE_URL=$ApiUrl/v1",
                        '-e', "API_PROXY_URL=$ApiUrl", '-e', "API_KEY_PLACEHOLDER=$Placeholder")
    } else {
        $agentArgs += @('-e', 'OLLAMA_API_KEY')   # real key, by name only
    }
    if ($Agent -eq "opencode") { $agentArgs += @('-v', 'opencode-cache:/home/agent/.cache/opencode') }
    if ($McpConfigResolved) {
        if ($Agent -eq "opencode") {
            $agentArgs += @('-v', "${McpConfigResolved}:/run/agent-mcp.json:ro", '-e', 'OPENCODE_CONFIG=/run/agent-mcp.json')
        } else {
            $agentArgs += @('-v', "${McpConfigResolved}:/home/agent/.copilot/mcp-config.json:ro")
        }
        Write-Host "MCP config: $McpConfigResolved (read-only, loaded at agent startup)"
    }

    wslc run --rm -it --name $Name --network $NetName @agentArgs --memory 4g --cpus 2 $Image
}
finally {
    $ErrorActionPreference = 'Continue'
    $stamp = Get-Date -Format yyyyMMdd-HHmmss
    $logContainers = @($ProxyName)
    if ($Inject) { $logContainers += $ApiName }
    if ($Tor) { $logContainers += $TorName }
    foreach ($c in $logContainers) {
        $log = Join-Path $LogDir "$Name-$stamp-$($c -replace "-$([regex]::Escape($Name))$", '').log"
        wslc container logs $c *> $log
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) { Write-Host "Log: $log" } else { Remove-Item $log -ErrorAction SilentlyContinue }
    }
    foreach ($c in @($ProxyName, $ApiName, $ViewerName, $TorName)) {
        wslc container stop $c 2>$null | Out-Null
        wslc container rm   $c 2>$null | Out-Null
    }
    wslc network rm $MonNet  2>$null | Out-Null
    wslc network rm $TorNet  2>$null | Out-Null
    wslc network rm $NetName 2>$null | Out-Null
    Remove-Item Env:OLLAMA_API_KEY, Env:MGR_PASSWORD -ErrorAction SilentlyContinue
    if ($GitHubTokenSet) { Remove-Item Env:COPILOT_GITHUB_TOKEN -ErrorAction SilentlyContinue }   # only if loaded from the vault
}
