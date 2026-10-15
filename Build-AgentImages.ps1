<#
.SYNOPSIS
  Builds the images used by the agent and restricted-container launchers via wslc.
.DESCRIPTION
  Each image folder is its own build context. Tags match the agent and restricted-container
  launcher defaults, so a session started after this script uses the freshly built images.
  Any additional root-level folder containing a Dockerfile is discovered by -Images all and can
  also be selected directly by folder name. Stops at the first failed build.
.EXAMPLE
  .\Build-AgentImages.ps1                                  # all images
  .\Build-AgentImages.ps1 -Agent opencode                  # opencode agent + all sidecars
  .\Build-AgentImages.ps1 -Agent copilot -Exclude tor-gateway
  .\Build-AgentImages.ps1 -Images opencode,api-proxy,proxy
  .\Build-AgentImages.ps1 -Images copilot -AgentVersion 1.0.4 -NoCache
  .\Build-AgentImages.ps1 -Images all -Exclude tor-gateway,monitor
  .\Build-AgentImages.ps1 -Images proxy,monitor,generic-alpine
  .\Build-AgentImages.ps1 -Images my-container                # ./my-container/Dockerfile -> my-container:local
#>
param(
    [string[]]$Images = @("all"),

    [string[]]$Exclude = @(),

    # Which agent image(s) to build; "github" is an alias for the GitHub Copilot CLI image.
    [ValidateSet("all", "opencode", "copilot", "github")]
    [string]$Agent = "all",

    [string]$AgentVersion  = "",
    [string]$AlpineVersion = "",
    [switch]$NoCache
)
# Native wslc errors are checked via $LASTEXITCODE (Stop + 2>&1 misbehaves in Windows PowerShell 5.1).
$ErrorActionPreference = 'Stop'

if (-not (Get-Command wslc -ErrorAction SilentlyContinue)) { throw "wslc not found in PATH. Install or update WSL." }
if ($AgentVersion  -and $AgentVersion  -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid -AgentVersion '$AgentVersion'." }
if ($AlpineVersion -and $AlpineVersion -notmatch '^[0-9]+\.[0-9]+(\.[0-9]+)?$')   { throw "Invalid -AlpineVersion '$AlpineVersion'." }

# Name -> tag, build context and image-specific build args. Tags match the launcher defaults.
$catalog = [ordered]@{
    "opencode"    = @{ Tag = "opencode-alpine:local";      Context = "agent";       Args = @('--build-arg', 'AGENT=opencode') }
    "copilot"     = @{ Tag = "copilot-alpine:local";       Context = "agent";       Args = @('--build-arg', 'AGENT=copilot') }
    "api-proxy"   = @{ Tag = "agent-api-proxy:local";      Context = "api-proxy";   Args = @() }
    "proxy"       = @{ Tag = "agent-egress-proxy:local";   Context = "proxy";       Args = @() }
    "monitor"     = @{ Tag = "agent-egress-monitor:local"; Context = "monitor";     Args = @() }
    "tor-gateway" = @{ Tag = "agent-tor-gateway:local";    Context = "tor-gateway"; Args = @() }
}

$requested = @()
if ($Images -contains "all") {
    $requested += $catalog.Keys
    $knownContexts = @($catalog.Values | ForEach-Object { $_.Context })
    $discovered = Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'Dockerfile') -PathType Leaf) -and
        $_.Name -notin $knownContexts
    } | ForEach-Object { $_.Name }
    $requested += $discovered
}
$requested += @($Images | Where-Object { $_ -ne "all" })
$requested = @($requested | Select-Object -Unique | Where-Object { $Exclude -notcontains $_ })

if ($Agent -ne "all") {
    $keep = if ($Agent -eq "github") { "copilot" } else { $Agent }
    $requested = @($requested | Where-Object { $_ -notin @("opencode", "copilot") -or $_ -eq $keep })
}
if (-not $requested) { throw "No images selected." }

# Known names retain their established tags and build arguments. Any other safe relative folder is
# accepted when it contains a Dockerfile; its tag is derived as <path-with-dashes>:local. Root-level
# folders with a Dockerfile are also discovered automatically by -Images all.
$selected = @()
foreach ($name in $requested) {
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)*$') {
        throw "Invalid image folder '$name'. Use a relative folder with letters, numbers, dots, underscores, dashes, and forward slashes only."
    }
    if ($catalog.Contains($name)) {
        $known = $catalog[$name]
        $selected += [pscustomobject]@{ Name = $name; Tag = $known.Tag; Context = $known.Context; Args = $known.Args }
        continue
    }

    $contextPath = Join-Path $PSScriptRoot $name
    $dockerfile = Join-Path $contextPath 'Dockerfile'
    if (-not (Test-Path -LiteralPath $contextPath -PathType Container) -or
        -not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) {
        throw "Unknown image '$name': '$name/Dockerfile' does not exist."
    }
    $tagName = ($name -replace '/', '-').ToLowerInvariant()
    $selected += [pscustomobject]@{ Name = $name; Tag = "${tagName}:local"; Context = $name; Args = @() }
}

$common = @()
if ($NoCache)       { $common += '--no-cache' }
if ($AlpineVersion) { $common += @('--build-arg', "ALPINE_VERSION=$AlpineVersion") }

$results = @()
Push-Location $PSScriptRoot
try {
    foreach ($img in $selected) {
        $name = $img.Name
        $buildArgs = $common + $img.Args
        if ($AgentVersion -and $img.Context -eq "agent") { $buildArgs += @('--build-arg', "AGENT_VERSION=$AgentVersion") }

        Write-Host "==> $name : wslc build -t $($img.Tag) $($buildArgs -join ' ') $($img.Context)" -ForegroundColor Cyan
        $sw = [Diagnostics.Stopwatch]::StartNew()
        wslc build -t $img.Tag @buildArgs $img.Context
        $code = $LASTEXITCODE
        $sw.Stop()
        $results += [pscustomobject]@{ Image = $name; Tag = $img.Tag; Result = $(if ($code -eq 0) { "ok" } else { "FAILED ($code)" }); Seconds = [int]$sw.Elapsed.TotalSeconds }
        if ($code -ne 0) { throw "wslc build failed for $name ($($img.Tag)), exit $code" }
    }
}
finally {
    Pop-Location
    if ($results) { $results | Format-Table -AutoSize | Out-Host }
}
