<#
.SYNOPSIS
  Runs an arbitrary container with proxy-only, allowlisted egress and optional monitoring/Tor.
.DESCRIPTION
  The workload is attached only to an internal WSLc network. A Squid sidecar is its sole HTTP(S)
  exit and permits HTTPS :443 only to -AllowDomains by default. The workload image is not modified.

  Sidecars, networks and the workload are removed on exit. Proxy and Tor logs are retained below
  <SessionRoot>\_proxy-logs. The image's normal entrypoint is preserved unless -Entrypoint is used.
.EXAMPLE
  .\Start-RestrictedContainer.ps1 -Image alpine:3.22 -Shell -AllowDomains example.com -Monitor
.EXAMPLE
  .\Start-RestrictedContainer.ps1 -Image alpine:3.22 -AllowDomains example.com -- wget -qO- https://example.com
.EXAMPLE
  .\Start-RestrictedContainer.ps1 -Image my-app:local -AllowDomains api.example.com -Monitor
.EXAMPLE
  .\Start-RestrictedContainer.ps1 -Image my-app:local -Environment APP_MODE=test -Volume 'C:\data:/data:ro'
.EXAMPLE
  .\Start-RestrictedContainer.ps1 -Image my-app:local -Tor -Monitor -AllowDomains api.example.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Image,

    [string]$SessionRoot = "C:\temp\wslc-container-sessions",
    [string]$Session = "container-$(Get-Date -Format yyyyMMdd-HHmmss)",

    [string[]]$AllowDomains = @(),
    [string[]]$DenyDomains = @(),
    [switch]$AllowAllDomains,
    [switch]$AllowHttp,

    [string[]]$Environment = @(),
    [string[]]$PassEnvironment = @(),
    [string[]]$Volume = @(),
    [string[]]$Publish = @(),
    [string]$Entrypoint = "",
    [string]$Memory = "4g",
    [double]$Cpus = 2,
    [switch]$NoTty,
    [switch]$Shell,
    [string]$ShellPath = "/bin/sh",
    [switch]$RunAsRoot,

    [string]$ProxyImage = "agent-egress-proxy:local",
    [int]$ProxyStartTimeoutSec = 30,

    [switch]$Monitor,
    [int]$MonitorPort = 8081,
    [string]$MonitorBind = "127.0.0.1",
    [string]$MonitorImage = "agent-egress-monitor:local",
    [switch]$NoBrowser,

    [switch]$Tor,
    [string]$TorImage = "agent-tor-gateway:local",
    [int]$TorStartTimeoutSec = 60,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Command = @()
)

$ErrorActionPreference = 'Stop'
# Native exit codes are handled explicitly so an expected nonzero workload exit can be preserved
# after cleanup even when the caller enabled PowerShell 7's native-error preference.
$PSNativeCommandUseErrorActionPreference = $false

function Assert-Wslc([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "wslc failed: $Step (exit $LASTEXITCODE)" }
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
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($BindAddress), $Port)
        $listener.Start()
        return $true
    }
    catch { return $false }
    finally { if ($listener) { $listener.Stop() } }
}

function Test-HttpOk([string]$Url, [int]$TimeoutMs = 2000) {
    $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Proxy = $null
        $req.Timeout = $TimeoutMs
        $resp = $req.GetResponse()
        return ([int]$resp.StatusCode -eq 200)
    }
    catch {
        $script:LastHealthError = $_.Exception.InnerException.Message
        if (-not $script:LastHealthError) { $script:LastHealthError = $_.Exception.Message }
        return $false
    }
    finally { if ($resp) { $resp.Close() } }
}

function Normalize-Domains([string[]]$Values, [string]$ParameterName) {
    $joined = (($Values -join ' ') -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($domain in $joined) {
        if ($domain -notmatch '^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') {
            throw "Invalid domain '$domain' in -$ParameterName. Use hostnames only, separated by commas or spaces."
        }
    }
    return @($joined | Select-Object -Unique)
}

function Test-DomainCovered([string]$Domain, [string[]]$Rules) {
    foreach ($rule in $Rules) {
        if ($rule.StartsWith('.')) {
            $base = $rule.Substring(1)
            if ($Domain -eq $base -or $Domain.EndsWith(".$base")) { return $true }
        } elseif ($Domain -eq $rule) { return $true }
    }
    return $false
}

function Assert-NoRedundantDomainRules([string[]]$Rules) {
    foreach ($rule in $Rules | Where-Object { $_.StartsWith('.') }) {
        if ($Rules -contains $rule.Substring(1)) {
            throw "Do not list both '$rule' and '$($rule.Substring(1))'; the leading-dot form already includes the base domain."
        }
    }
}

if (-not (Get-Command wslc -ErrorAction SilentlyContinue)) { throw "wslc not found in PATH. Install or update WSL." }
if ($Session -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw "Invalid session name: $Session" }
if ($ProxyStartTimeoutSec -lt 1) { throw "-ProxyStartTimeoutSec must be at least 1 second." }
if ($TorStartTimeoutSec -lt 1) { throw "-TorStartTimeoutSec must be at least 1 second." }
if ($Cpus -le 0 -or [double]::IsNaN($Cpus) -or [double]::IsInfinity($Cpus)) { throw "-Cpus must be a finite number greater than zero." }
if ($Memory -notmatch '^[1-9][0-9]*(\.\d+)?[kmgt]?$') { throw "Invalid -Memory '$Memory' (examples: 512m, 4g)." }
foreach ($imageValue in @($Image, $ProxyImage, $MonitorImage, $TorImage)) {
    if (-not $imageValue -or $imageValue.StartsWith('-') -or $imageValue -match '[\r\n]') { throw "Invalid image name '$imageValue'." }
}
if ($Entrypoint -match '[\r\n]') { throw "-Entrypoint cannot contain newlines." }
if (-not $ShellPath -or $ShellPath.StartsWith('-') -or $ShellPath -match '[\r\n]') { throw "Invalid -ShellPath '$ShellPath'." }

$AllowDomains = @(Normalize-Domains -Values $AllowDomains -ParameterName 'AllowDomains')
$DenyDomains = @(Normalize-Domains -Values $DenyDomains -ParameterName 'DenyDomains')
Assert-NoRedundantDomainRules -Rules $AllowDomains
Assert-NoRedundantDomainRules -Rules $DenyDomains
$AlpineCdn = 'dl-cdn.alpinelinux.org'
if ($RunAsRoot) {
    if (Test-DomainCovered $AlpineCdn $DenyDomains) {
        throw "-RunAsRoot requires $AlpineCdn for apk, but that host is covered by -DenyDomains."
    }
    if (-not $AllowAllDomains -and -not (Test-DomainCovered $AlpineCdn $AllowDomains)) {
        $AllowDomains += $AlpineCdn
        Write-Host "Run-as-root package access: added $AlpineCdn to the HTTPS allowlist."
    }
}
if ($AllowAllDomains -and $AllowDomains.Count) { Write-Warning "-AllowDomains is ignored with -AllowAllDomains." }
if ($AllowAllDomains) { Write-Warning "Allow-all permits HTTPS egress to every domain; use it only for short discovery runs." }
if ($AllowHttp) { Write-Warning "Plain HTTP is enabled and may expose or permit modification of traffic." }

if ($Monitor) {
    if ($MonitorBind -ne '127.0.0.1') {
        throw "-MonitorBind must be 127.0.0.1. The monitor has no authentication."
    }
    if ($MonitorPort -lt 1 -or $MonitorPort -gt 65535) { throw "-MonitorPort must be between 1 and 65535." }
    if (-not (Test-TcpPortAvailable $MonitorBind $MonitorPort)) {
        throw "Monitor port ${MonitorBind}:$MonitorPort is already in use."
    }
}

$reservedEnvironment = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY')) { [void]$reservedEnvironment.Add($name) }
$customEnvironmentArgs = @()
foreach ($item in $Environment) {
    if ($item -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { throw "Invalid -Environment value '$item'; expected NAME=value." }
    if ($reservedEnvironment.Contains($Matches[1])) { throw "Environment variable '$($Matches[1])' is managed by the launcher and cannot be overridden." }
    if ($item.Contains("`n") -or $item.Contains("`r")) { throw "Environment values cannot contain newlines." }
    $customEnvironmentArgs += @('-e', $item)
}
foreach ($name in $PassEnvironment) {
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid -PassEnvironment name '$name'." }
    if ($reservedEnvironment.Contains($name)) { throw "Environment variable '$name' is managed by the launcher and cannot be overridden." }
    if (-not (Test-Path "Env:$name")) { throw "Host environment variable '$name' is not set." }
    $customEnvironmentArgs += @('-e', $name)
}

$volumeArgs = @()
foreach ($mount in $Volume) {
    if (-not $mount -or $mount.Contains("`n") -or $mount.Contains("`r")) { throw "Invalid -Volume value." }
    $volumeArgs += @('-v', $mount)
}
$publishArgs = @()
$publishedHostPorts = [Collections.Generic.HashSet[int]]::new()
foreach ($mapping in $Publish) {
    if ($mapping -notmatch '^127\.0\.0\.1:([0-9]{1,5}):([0-9]{1,5})$') {
        throw "Invalid -Publish '$mapping'. Use 127.0.0.1:<host-port>:<container-port>; non-localhost bindings are refused."
    }
    foreach ($port in @([int]$Matches[1], [int]$Matches[2])) {
        if ($port -lt 1 -or $port -gt 65535) { throw "Invalid port in -Publish '$mapping'." }
    }
    $hostPort = [int]$Matches[1]
    if (-not $publishedHostPorts.Add($hostPort)) { throw "Published host port $hostPort is specified more than once." }
    if ($Monitor -and $hostPort -eq $MonitorPort) { throw "Published host port $hostPort conflicts with -MonitorPort." }
    if (-not (Test-TcpPortAvailable '127.0.0.1' $hostPort)) { throw "Published host port $hostPort is already in use." }
    $publishArgs += @('-p', $mapping)
}

if ($Command.Count -and $Command[0] -eq '--') { $Command = @($Command | Select-Object -Skip 1) }
if ($Shell -and $Command.Count) { throw "-Shell cannot be combined with a workload command." }
if ($Shell -and $Entrypoint) { throw "-Shell cannot be combined with -Entrypoint." }
if ($Shell -and $NoTty) { throw "-Shell cannot be combined with -NoTty." }

$netHelp = (wslc network create --help 2>&1) -join "`n"
if ($netHelp -notmatch '--internal') {
    throw "This wslc build has no 'network create --internal'. The workload cannot be isolated; update WSL."
}

$Name = $Session.ToLowerInvariant()
$NetName = "ctr-int-$Name"
$ProxyName = "ctr-proxy-$Name"
$MonNet = "ctr-mon-$Name"
$ViewerName = "ctr-monitor-$Name"
$TorNet = "ctr-tor-$Name"
$TorName = "ctr-tor-gateway-$Name"
$ProxyUrl = "http://${ProxyName}:3128"
$AllowDomainString = $AllowDomains -join ' '
$DenyDomainString = $DenyDomains -join ' '
$LogDir = Join-Path $SessionRoot '_proxy-logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$oldManagerPassword = $env:MGR_PASSWORD
$managerPasswordWasSet = Test-Path Env:MGR_PASSWORD
$workloadStarted = $false
$workloadExitCode = 0
$createdNet = $false
$createdMonNet = $false
$createdTorNet = $false
$startedProxy = $false
$startedMonitor = $false
$startedTor = $false

# Refuse name collisions before entering the cleanup scope. This prevents a failed launch from
# stopping or deleting resources owned by another session.
$containerNames = @($Name, $ProxyName)
if ($Monitor) { $containerNames += $ViewerName }
if ($Tor) { $containerNames += $TorName }
foreach ($container in $containerNames) {
    wslc container inspect $container *> $null
    if ($LASTEXITCODE -eq 0) { throw "Container '$container' already exists. Choose another -Session." }
}
$networkNames = @($NetName)
if ($Monitor -and -not $Tor) { $networkNames += $MonNet }
if ($Tor) { $networkNames += $TorNet }
foreach ($network in $networkNames) {
    wslc network inspect $network *> $null
    if ($LASTEXITCODE -eq 0) { throw "Network '$network' already exists. Choose another -Session or remove the stale network." }
}

try {
    Write-Host "Restricted container '$Name' ($Image): creating proxy-only network"
    wslc network create --internal $NetName | Out-Null; Assert-Wslc 'internal network create'
    $createdNet = $true

    $TorExitIp = ''
    if ($Tor) {
        wslc network create --internal $TorNet | Out-Null; Assert-Wslc 'Tor transit network create'
        $createdTorNet = $true
        wslc run -d --name $TorName --memory 256m --cpus 0.5 $TorImage | Out-Null; Assert-Wslc 'Tor gateway run'
        $startedTor = $true
        wslc network connect $TorNet $TorName; Assert-Wslc 'Tor gateway network connect'
        Wait-ContainerLog $TorName 'tor-gateway: ready exit_ip=' $TorStartTimeoutSec
        $torLogs = (wslc container logs $TorName 2>&1) -join "`n"
        $TorExitIp = [regex]::Match($torLogs, 'tor-gateway: ready exit_ip=([^\s]+)').Groups[1].Value
        if (-not $TorExitIp) { throw 'Tor gateway reported ready without a verified exit IP.' }
        Write-Host "Tor gateway ready: verified exit $TorExitIp"
    }

    $egressNet = @()
    $logTarget = @()
    if ($Monitor) {
        $chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $pw = [Text.StringBuilder]::new()
        $buf = New-Object byte[] 64
        while ($pw.Length -lt 32) {
            $rng.GetBytes($buf)
            foreach ($b in $buf) { if ($b -lt 248 -and $pw.Length -lt 32) { [void]$pw.Append($chars[$b % 62]) } }
        }
        $env:MGR_PASSWORD = $pw.ToString()

        if (-not $Tor) {
            wslc network create $MonNet | Out-Null; Assert-Wslc 'monitor network create'
            $createdMonNet = $true
            $monitorRunNet = @('--network', $MonNet)
        } else { $monitorRunNet = @() }

        $publish = "${MonitorBind}:${MonitorPort}:8080"
        wslc run -d --name $ViewerName @monitorRunNet -p $publish `
            -e MGR_PASSWORD `
            -e "PROXY_MGR_URL=http://${ProxyName}:3128/squid-internal-mgr/active_requests" `
            -e "SESSION_NAME=$Name" `
            -e "TOR_MODE=$(if ($Tor) { '1' } else { '0' })" `
            -e "TOR_EXIT_IP=$TorExitIp" `
            --memory 256m --cpus 0.5 $MonitorImage | Out-Null; Assert-Wslc 'monitor run'
        $startedMonitor = $true
        if ($Tor) { wslc network connect $TorNet $ViewerName; Assert-Wslc 'monitor Tor network connect' }
        if (-not $Tor) { $egressNet = @('--network', $MonNet) }
        $logTarget = @('-e', "VIEWER_LOG_TARGET=${ViewerName}:5140")
    }

    $squidArgs = @(
        '-e', "PROXY_ALLOW_DOMAINS=$AllowDomainString",
        '-e', "PROXY_DENY_DOMAINS=$DenyDomainString",
        '-e', "PROXY_HOSTNAME=$ProxyName",
        '-e', "PROXY_ALLOW_HTTP=$(if ($AllowHttp) { '1' } else { '0' })"
    ) + $logTarget
    if ($AllowAllDomains) { $squidArgs += @('-e', 'PROXY_ALLOW_ALL=1') }
    if ($Monitor) { $squidArgs += @('-e', 'MGR_PASSWORD') }
    if ($Tor) { $squidArgs += @('-e', "PROXY_PARENT_HOST=$TorName") }
    $squidNet = if ($Tor) { @('--network', $TorNet) } else { $egressNet }

    wslc run -d --name $ProxyName @squidNet @squidArgs --memory 256m --cpus 0.5 $ProxyImage | Out-Null; Assert-Wslc 'proxy run'
    $startedProxy = $true
    wslc network connect $NetName $ProxyName; Assert-Wslc 'proxy internal network connect'
    Wait-ContainerLog $ProxyName 'Accepting HTTP Socket connections' $ProxyStartTimeoutSec
    $ports = if ($AllowHttp) { 'HTTPS :443 and HTTP :80' } else { 'HTTPS :443 only' }
    $policy = if ($AllowAllDomains) { "all domains ($ports)" } elseif ($AllowDomainString) { "$AllowDomainString ($ports)" } else { 'deny all' }
    Write-Host "Egress proxy ready: $policy"

    if ($Monitor) {
        $url = "http://localhost:$MonitorPort/"
        $probeUrl = "http://${MonitorBind}:$MonitorPort/healthz"
        $ok = $false
        for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
            $ok = Test-HttpOk $probeUrl
            if (-not $ok) { Start-Sleep -Milliseconds 500 }
        }
        if ($ok) { Write-Host "Egress monitor: $url" }
        else { Write-Warning "Monitor health check failed ($script:LastHealthError); the workload will continue." }
        if (-not $NoBrowser) { Start-Process $url }
    }

    $workloadArgs = @(
        '--rm', '--name', $Name, '--network', $NetName,
        '-e', "HTTPS_PROXY=$ProxyUrl", '-e', "HTTP_PROXY=$ProxyUrl", '-e', 'NO_PROXY=localhost,127.0.0.1',
        '-e', "https_proxy=$ProxyUrl", '-e', "http_proxy=$ProxyUrl", '-e', 'no_proxy=localhost,127.0.0.1'
    ) + $customEnvironmentArgs + $volumeArgs + $publishArgs
    $cpuValue = $Cpus.ToString([Globalization.CultureInfo]::InvariantCulture)
    $workloadArgs += @('--memory', $Memory, '--cpus', $cpuValue)
    if ($RunAsRoot) {
        Write-Warning "The workload will run as UID 0 inside its container."
        $workloadArgs += @('--user', '0')
    }

    if ($Shell) {
        # Keep the container alive without relying on its default command, then enter its shell.
        $workloadArgs += @('-d', '--entrypoint', 'sleep', $Image, 'infinity')
        Write-Host "Starting restricted workload '$Name', then entering $ShellPath. Exit the shell to tear down the session."
        wslc run @workloadArgs | Out-Null
        Assert-Wslc 'workload run for shell session'
        $workloadStarted = $true
        if ($RunAsRoot) { wslc exec -it -u 0 $Name $ShellPath }
        else { wslc exec -it $Name $ShellPath }
        $workloadExitCode = $LASTEXITCODE
    } else {
        if (-not $NoTty) { $workloadArgs += '-it' }
        if ($Entrypoint) { $workloadArgs += @('--entrypoint', $Entrypoint) }
        $workloadArgs += $Image
        $workloadArgs += $Command
        Write-Host "Starting workload '$Name'. Applications must use HTTP(S) proxy variables; direct egress has no route."
        $workloadStarted = $true
        wslc run @workloadArgs
        $workloadExitCode = $LASTEXITCODE
    }
}
finally {
    $ErrorActionPreference = 'Continue'
    $stamp = Get-Date -Format yyyyMMdd-HHmmss
    $logContainers = @()
    if ($startedProxy) { $logContainers += $ProxyName }
    if ($startedTor) { $logContainers += $TorName }
    foreach ($c in $logContainers) {
        if (-not $c) { continue }
        $kind = $c -replace "-$([regex]::Escape($Name))$", ''
        $log = Join-Path $LogDir "$Name-$stamp-$kind.log"
        wslc container logs $c *> $log
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) { Write-Host "Log: $log" }
        else { Remove-Item $log -ErrorAction SilentlyContinue }
    }
    $cleanupContainers = @()
    if ($workloadStarted) { $cleanupContainers += $Name }
    if ($startedProxy) { $cleanupContainers += $ProxyName }
    if ($startedMonitor) { $cleanupContainers += $ViewerName }
    if ($startedTor) { $cleanupContainers += $TorName }
    foreach ($c in $cleanupContainers) {
        wslc container stop $c 2>$null | Out-Null
        wslc container rm $c 2>$null | Out-Null
    }
    if ($createdMonNet) { wslc network rm $MonNet 2>$null | Out-Null }
    if ($createdTorNet) { wslc network rm $TorNet 2>$null | Out-Null }
    if ($createdNet) { wslc network rm $NetName 2>$null | Out-Null }
    if ($managerPasswordWasSet) { $env:MGR_PASSWORD = $oldManagerPassword }
    else { Remove-Item Env:MGR_PASSWORD -ErrorAction SilentlyContinue }
}

if ($workloadStarted -and $workloadExitCode -ne 0) { exit $workloadExitCode }
