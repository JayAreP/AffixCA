# =============================================================================
#  Common  ·  GET /api/health — Simple liveness probe
#  GET /api/status — CA identity, roles, stats, initialization state
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/health' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    $resp = @{
        status      = 'ok'
        initialized = ($null -ne $cfg)
        timestamp   = (Get-Date -Format 'o')
    }
    if ($cfg) {
        $resp.caName = $cfg.caName
        $resp.roles  = @($cfg.roles)
    }
    Write-PodeJsonResponse -Value $resp
}

Add-PodeRoute -Method 'Get' -Path '/api/status' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $cfg = Get-InstanceConfig
    $init = ($null -ne $cfg)

    $info = @{
        initialized = $init
        online      = $true
        roles       = @()
        standalone  = $false
        caName      = 'Affix/CA'
        caSubject   = ''
        stats       = @{ total = 0; valid = 0; revoked = 0; expired = 0; expiring = 0 }
        tiers       = @{}
        templates   = @()
    }

    if ($init) {
        $info.roles      = @($cfg.roles)
        $info.standalone = ($cfg.standalone -eq $true)
        $info.caName     = $cfg.caName ?? 'Affix/CA'
        $info.templates  = @($cfg.templates ?? @())
        $info.keyAlgo    = $cfg.keyAlgo ?? 'rsa'
        $info.keyParam   = $cfg.keyParam ?? '4096'
        $info.cdpUrl     = $cfg.cdpUrl ?? ''
        $info.aiaUrl     = $cfg.aiaUrl ?? ''
        $info.ocspUrl    = $cfg.ocspUrl ?? ''
        $info.subject    = $cfg.subject ?? @{}

        # Build tier info for each role
        foreach ($role in $cfg.roles) {
            $caDir = Get-CADir -Tier $role -Config $cfg
            $certPath = "$caDir/certs/ca.crt"
            $tierInfo = @{ initialized = $false }

            if (Test-Path $certPath) {
                try {
                    $ci = Get-CertInfo -CertPath $certPath
                    $cn = ($ci.subject -split ',\s*' | Where-Object { $_ -match '^\s*CN\s*=' } | Select-Object -First 1) -replace '^\s*CN\s*=\s*', ''
                    $tierInfo = @{
                        initialized    = $true
                        serial         = $ci.serial
                        subject        = $ci.subject
                        caName         = $cn.Trim()
                        notBefore      = $ci.notBefore
                        notAfter       = $ci.notAfter
                        daysUntilExpiry = $ci.daysUntilExp
                        fingerprint    = $ci.fingerprint
                    }
                } catch {
                    Write-Log -Category 'errors' -Level 'error' -Message "Status error for tier $role : $_"
                }
            }
            $info.tiers[$role] = $tierInfo
        }

        # Aggregate stats from the issuing tier (where end-entity certs are issued)
        $issuingDir = Get-CADir -Tier 'issuing' -Config $cfg
        if ('issuing' -in $cfg.roles -and (Test-Path "$issuingDir/db/index.txt")) {
            $dbStats = Get-DBStats -CADir $issuingDir
            $certs   = Get-CertList -CADir $issuingDir
            $info.stats = @{
                total    = $dbStats.total
                valid    = $dbStats.valid
                revoked  = $dbStats.revoked
                expired  = $dbStats.expired
                expiring = ($certs | Where-Object { $_.status -eq 'expiring' }).Count
            }
        }

        # Include parent URL for distributed non-root nodes
        if ($cfg.parentUrl) {
            $info.parentUrl = $cfg.parentUrl
        }

        # Set top-level cert info from root tier (or first available)
        $primaryTier = if ('root' -in $cfg.roles) { 'root' } else { $cfg.roles[0] }
        $primary = $info.tiers[$primaryTier]
        if ($primary -and $primary.initialized) {
            $info.caSubject     = $primary.subject
            $info.serial        = $primary.serial
            $info.notBefore     = $primary.notBefore
            $info.notAfter      = $primary.notAfter
            $info.daysUntilExpiry = $primary.daysUntilExpiry
            $info.fingerprint   = $primary.fingerprint
            if ($primary.caName) { $info.caName = $primary.caName }
        }
    }

    Write-PodeJsonResponse -Value $info
}
