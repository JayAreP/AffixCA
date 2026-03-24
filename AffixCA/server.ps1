# =============================================================================
#  Affix/CA  ·  Unified PODE Server Entrypoint
#  Loads routes based on the instance's configured roles (from /ca/config.json).
#  If unconfigured, serves the setup wizard.
# =============================================================================

$ErrorActionPreference = 'Stop'

. /app/shared/scripts/Common-Functions.ps1

# ── Read instance config (null if not yet set up) ────────────────────────────
$config = Get-InstanceConfig

if ($config) {
    $roles = @($config.roles)
    Write-Log -Category 'system' -Message "Roles: $($roles -join ', ') | Standalone: $($config.standalone)"

    # Apply custom DNS servers if configured
    if ($config.dnsServers) {
        try {
            $dnsServers = ($config.dnsServers -split '[,;\s]+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($dnsServers.Count -gt 0) {
                $dnsServers | ForEach-Object { "nameserver $_" } | Set-Content '/etc/resolv.conf' -Force
                Write-Log -Category 'system' -Message "DNS servers applied: $($dnsServers -join ', ')"
            }
        } catch {
            Write-Log -Category 'system' -Level 'warn' -Message "Could not apply DNS servers: $($_.Exception.Message)"
        }
    }
} else {
    $roles = @()
    Write-Log -Category 'system' -Message 'Not configured — setup wizard will be served.'
}

# ── Bootstrap web server TLS certificate ─────────────────────────────────────
$webCert = Initialize-WebServerCert

# ── PODE Server ──────────────────────────────────────────────────────────────
Import-Module Pode

Start-PodeServer -Threads 4 {

    # ── Initialize auth store (runs on every server start/restart) ────────
    . /app/shared/scripts/Common-Functions.ps1
    Write-Log -Category 'system' -Message 'Initializing auth store...'
    Initialize-AuthStore
    Write-Log -Category 'system' -Message 'Auth store ready.'

    Add-PodeEndpoint -Address '*' -Port 8443 -Protocol Https -Name 'HTTPS' `
        -Certificate $webCert.Cert -CertificateKey $webCert.Key

    # ── HTTP endpoint for public PKI distribution (CRL, AIA, chain) ────────
    Add-PodeEndpoint -Address '*' -Port 8080 -Protocol Http -Name 'HTTP'

    # ── Custom JSON body parser (overrides Pode built-in to avoid 400s) ──
    Add-PodeBodyParser -ContentType 'application/json' -ScriptBlock {
        param($body)
        if ([string]::IsNullOrWhiteSpace($body)) { return @{} }
        try { return ($body | ConvertFrom-Json) }
        catch { return @{} }
    }

    # ── Restrict HTTP to public PKI paths only ─────────────────────────────
    Add-PodeMiddleware -Name 'HttpPkiOnly' -ScriptBlock {
        $endpoint = $WebEvent.Endpoint.Name
        if ($endpoint -eq 'HTTP') {
            $path = $WebEvent.Path
            if (-not $path) { $path = $WebEvent.Request.Url.AbsolutePath }
            if (-not $path) { $path = '/' }

            # Allow public PKI endpoints + inter-node setup endpoints over HTTP
            if ($path -eq '/api/health' -or
                $path -like '/api/auth/login*' -or
                $path -eq '/api/status' -or
                $path -eq '/api/sign-csr' -or
                $path -like '/api/chain*' -or
                $path -like '/api/crl/*' -or
                $path -like '/api/ocsp*') {
                return $true
            }

            # Redirect everything else to HTTPS
            $reqHost = $WebEvent.Request.Host -replace ':\d+$', ''
            Move-PodeResponseUrl -Url "https://${reqHost}:8443${path}"
            return $false
        }
        return $true
    }

    # ── Authentication (must be registered before routes) ────────────────────
    Register-PodeAuth

    # ── Static UI ────────────────────────────────────────────────────────────
    Add-PodeStaticRoute -Path '/ui' -Source '/app/ui'

    # ── Root redirect ────────────────────────────────────────────────────────
    Add-PodeRoute -Method 'Get' -Path '/' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $cfg = Get-InstanceConfig
        if (-not $cfg) {
            Move-PodeResponseUrl -Url '/ui/setup.html'
        } else {
            Move-PodeResponseUrl -Url '/ui/index.html'
        }
    }

    # ── Always load common routes ────────────────────────────────────────────
    Use-PodeRoutes -Path '/app/routes/common'

    # ── Always load setup routes (they self-guard after setup is complete) ──
    Use-PodeRoutes -Path '/app/routes/setup'

    # ── Load role-specific routes ────────────────────────────────────────────
    $cfg = Get-InstanceConfig
    if ($cfg) {
        $activeRoles = @($cfg.roles)

        if ('root' -in $activeRoles) {
            Write-Log -Category 'system' -Message 'Loading root CA routes'
            Use-PodeRoutes -Path '/app/routes/root'
        }

        if ('intermediate' -in $activeRoles) {
            Write-Log -Category 'system' -Message 'Loading intermediate CA routes'
            Use-PodeRoutes -Path '/app/routes/intermediate'
        }

        if ('issuing' -in $activeRoles) {
            Write-Log -Category 'system' -Message 'Loading issuing CA routes'
            Use-PodeRoutes -Path '/app/routes/issuing'
        }
    }

    # ── Refresh chain from parent on startup (for distributed non-root nodes) ──
    if ($cfg -and $cfg.parentUrl -and $cfg.standalone -ne $true) {
        try {
            Write-Log -Category 'system' -Message "Refreshing chain from parent: $($cfg.parentUrl)"
            $parentChain = Invoke-RestMethod -Uri "$($cfg.parentUrl)/api/chain" `
                -TimeoutSec 5 -SkipCertificateCheck
            if ($parentChain.chain) {
                $chainDir = '/ca/chain'
                if (-not (Test-Path $chainDir)) { New-Item -ItemType Directory -Path $chainDir -Force | Out-Null }
                $parentChain.chain | Set-Content "$chainDir/chain.pem" -Force
                Write-Log -Category 'system' -Message "Chain refreshed ($($parentChain.count) certs from parent)"
            }
        } catch {
            Write-Log -Category 'system' -Level 'warn' -Message "Could not refresh chain from parent: $($_.Exception.Message)"
        }
    }

    # ── Logging ──────────────────────────────────────────────────────────────
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging
    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging

    Write-Log -Category 'system' -Message 'Pode server running on :8443 (HTTPS) + :8080 (HTTP/PKI-only)'
}
