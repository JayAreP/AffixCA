<#
.SYNOPSIS
    Builds the Affix/CA Docker image.

.PARAMETER NoCache
    Disable Docker layer cache (full rebuild).

.PARAMETER Version
    Override the auto-generated version tag. Defaults to yyyyMMdd-HHmmss.

.PARAMETER SkipRestart
    Skip the automatic container restart after build.

.EXAMPLE
    ./build.ps1
    ./build.ps1 -NoCache
#>
[CmdletBinding()]
param(
    [string] $Version,
    [switch] $NoCache,
    [switch] $SkipRestart
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot

# ── Version ─────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Date).ToString('yyyyMMdd-HHmmss')
}
$Version | Set-Content -Path (Join-Path $ProjectRoot 'version.txt') -NoNewline

# ── Ensure secrets exist ────────────────────────────────────────────────────
$secretsDir = Join-Path $ProjectRoot 'secrets'
if (-not (Test-Path $secretsDir)) { New-Item -ItemType Directory -Path $secretsDir | Out-Null }

$secretFile = Join-Path $secretsDir 'ca-pass.txt'
if (-not (Test-Path $secretFile)) {
    $random = openssl rand -base64 48 | ForEach-Object { $_ -replace "`n|`r", '' }
    [System.IO.File]::WriteAllText($secretFile, $random)
    Write-Host "  Created $secretFile" -ForegroundColor DarkGray
}

# ── Ensure .env exists ──────────────────────────────────────────────────────
$envFile = Join-Path $ProjectRoot '.env'
$envExample = Join-Path $ProjectRoot '.env.example'
if (-not (Test-Path $envFile) -and (Test-Path $envExample)) {
    Copy-Item $envExample $envFile
    Write-Host "  Copied .env.example -> .env" -ForegroundColor Yellow
}

# ── Build ────────────────────────────────────────────────────────────────────
$cacheFlag = if ($NoCache) { @('--no-cache') } else { @() }

Write-Host "`n=== Affix/CA Build ===" -ForegroundColor Cyan
Write-Host "  Version:   $Version" -ForegroundColor Gray
Write-Host "  Cache:     $(if ($NoCache) { 'disabled' } else { 'enabled' })" -ForegroundColor Gray

Write-Host "`nBuilding image..." -ForegroundColor Cyan
$buildCmd = @('docker', 'build') + $cacheFlag + @(
    '-t', "affix-ca:$Version",
    '-t', 'affix-ca:latest',
    '-f', (Join-Path $ProjectRoot 'Dockerfile'),
    $ProjectRoot
)
& $buildCmd[0] $buildCmd[1..($buildCmd.Length - 1)]
if ($LASTEXITCODE -ne 0) { throw "Image build failed" }

Write-Host "`n=== Build complete ===" -ForegroundColor Green
Write-Host "  Version: $Version" -ForegroundColor Green

# ── Bring services online ─────────────────────────────────────────────────
if (-not $SkipRestart) {
    Write-Host "`nBringing services online..." -ForegroundColor Yellow
    Push-Location $ProjectRoot
    try {
        docker compose down 2>$null
        docker compose up -d
        Write-Host "  Services online." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "  Open https://localhost:$($env:CA_PORT ?? '443') to begin setup" -ForegroundColor Gray
Write-Host ""
