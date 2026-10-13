<#
.SYNOPSIS
  Builds the container images used by Start-AgentSidecar.ps1 via wslc.
.DESCRIPTION
  Each image folder is its own build context. Tags match the launcher defaults, so a session
  started after this script uses the freshly built images. Stops at the first failed build.
.EXAMPLE
  .\Build-AgentImages.ps1                                  # all images
  .\Build-AgentImages.ps1 -Agent opencode                  # opencode agent + all sidecars
  .\Build-AgentImages.ps1 -Agent copilot -Exclude tor-gateway
  .\Build-AgentImages.ps1 -Images opencode,api-proxy,proxy
  .\Build-AgentImages.ps1 -Images copilot -AgentVersion 1.0.4 -NoCache
  .\Build-AgentImages.ps1 -Images all -Exclude tor-gateway,monitor
#>
param(
    [ValidateSet("all", "opencode", "copilot", "api-proxy", "proxy", "monitor", "tor-gateway")]
    [string[]]$Images = @("all"),

    [ValidateSet("opencode", "copilot", "api-proxy", "proxy", "monitor", "tor-gateway")]
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

# Name -> tag, build context and image-specific build args. Tags must match Start-AgentSidecar.ps1 defaults.
$catalog = [ordered]@{
    "opencode"    = @{ Tag = "opencode-alpine:local";      Context = "agent";       Args = @('--build-arg', 'AGENT=opencode') }
    "copilot"     = @{ Tag = "copilot-alpine:local";       Context = "agent";       Args = @('--build-arg', 'AGENT=copilot') }
    "api-proxy"   = @{ Tag = "agent-api-proxy:local";      Context = "api-proxy";   Args = @() }
    "proxy"       = @{ Tag = "agent-egress-proxy:local";   Context = "proxy";       Args = @() }
    "monitor"     = @{ Tag = "agent-egress-monitor:local"; Context = "monitor";     Args = @() }
    "tor-gateway" = @{ Tag = "agent-tor-gateway:local";    Context = "tor-gateway"; Args = @() }
}

$selected = if ($Images -contains "all") { @($catalog.Keys) } else { @($catalog.Keys | Where-Object { $Images -contains $_ }) }
$selected = @($selected | Where-Object { $Exclude -notcontains $_ })
if ($Agent -ne "all") {
    $keep = if ($Agent -eq "github") { "copilot" } else { $Agent }
    $selected = @($selected | Where-Object { $_ -notin @("opencode", "copilot") -or $_ -eq $keep })
}
if (-not $selected) { throw "No images selected." }

$common = @()
if ($NoCache)       { $common += '--no-cache' }
if ($AlpineVersion) { $common += @('--build-arg', "ALPINE_VERSION=$AlpineVersion") }

$results = @()
Push-Location $PSScriptRoot
try {
    foreach ($name in $selected) {
        $img = $catalog[$name]
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
