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
    Write-Host "[Affix/CA] Roles: $($roles -join ', ') | Standalone: $($config.standalone)"
} else {
    $roles = @()
    Write-Host '[Affix/CA] Not configured — setup wizard will be served.'
}

# ── Initialize auth store (creates default admin user on first run) ──────────
Initialize-AuthStore

# ── Bootstrap web server TLS certificate ─────────────────────────────────────
$webCert = Initialize-WebServerCert

# ── PODE Server ──────────────────────────────────────────────────────────────
Import-Module Pode

Start-PodeServer -Threads 4 {

    Add-PodeEndpoint -Address '*' -Port 8443 -Protocol Https `
        -Certificate $webCert.Cert -CertificateKey $webCert.Key

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
            Write-Host '[Affix/CA] Loading root CA routes...'
            Use-PodeRoutes -Path '/app/routes/root'
        }

        if ('intermediate' -in $activeRoles) {
            Write-Host '[Affix/CA] Loading intermediate CA routes...'
            Use-PodeRoutes -Path '/app/routes/intermediate'
        }

        if ('issuing' -in $activeRoles) {
            Write-Host '[Affix/CA] Loading issuing CA routes...'
            Use-PodeRoutes -Path '/app/routes/issuing'
        }
    }

    # ── Logging ──────────────────────────────────────────────────────────────
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging
    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging

    Write-Host "[Affix/CA] PODE server running on :8443 (HTTPS)"
}
