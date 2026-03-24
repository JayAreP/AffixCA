# =============================================================================
#  Common  ·  Topology API endpoints
#  GET  /api/topology              — Get parent/subordinate relationships
#  POST /api/subordinates/evict    — Revoke and untrack a subordinate CA
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/topology' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Write-PodeJsonResponse -Value @{ configured = $false }
        return
    }

    # Self info
    $selfInfo = @{
        caName     = $cfg.caName
        roles      = @($cfg.roles)
        instanceId = $cfg.instanceId
        standalone = ($cfg.standalone -eq $true)
    }

    # Parent info (if any)
    $parentInfo = $null
    if ($cfg.parentUrl) {
        $parentInfo = @{
            url       = $cfg.parentUrl
            reachable = $false
            caName    = $null
        }
        try {
            $health = Invoke-RestMethod -Uri "$($cfg.parentUrl)/api/health" `
                -TimeoutSec 3 -SkipCertificateCheck
            $parentInfo.reachable = $true
            $parentInfo.caName = $health.caName
            $parentInfo.initialized = $health.initialized
        } catch {}
    }

    # Ancestors — parse the trust chain to extract CA names for each tier above us
    $ancestors = @()
    $chainFile = '/ca/chain/chain.pem'
    Write-Log -Category 'topology' -Level 'debug' -Message "Chain file exists: $(Test-Path $chainFile)"
    if (Test-Path $chainFile) {
        $chainText = Get-Content $chainFile -Raw
        $pemBlocks = [regex]::Matches($chainText, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
        foreach ($block in $pemBlocks) {
            $tmpFile = "/tmp/anc-$([System.Guid]::NewGuid().ToString('N')).crt"
            $block.Value | Set-Content $tmpFile
            try {
                $ci = Get-CertInfo -CertPath $tmpFile
                $cn = ($ci.subject -split ',\s*' | Where-Object { $_ -match '^\s*CN\s*=' } | Select-Object -First 1) -replace '^\s*CN\s*=\s*', ''
                $ancestors += @{ cn = $cn.Trim(); subject = $ci.subject; serial = $ci.serial }
                Write-Log -Category 'topology' -Level 'debug' -Message "Ancestor found: $($cn.Trim())"
            } catch {
                Write-Log -Category 'topology' -Level 'debug' -Message "Ancestor parse error: $($_.Exception.Message)"
            } finally {
                Remove-Item $tmpFile -ErrorAction SilentlyContinue
            }
        }
    }

    # Subordinates — use tracked list, or backfill from OpenSSL database
    $subordinates = @()
    if ($cfg.PSObject.Properties.Name -contains 'subordinates') {
        $subordinates = @($cfg.subordinates)
    }
    Write-Log -Category 'topology' -Level 'debug' -Message "Tracked subordinates: $($subordinates.Count) | roles: $($cfg.roles -join ',')"

    # Backfill: if no tracked subordinates, scan OpenSSL index.txt for issued certs
    $roles = @($cfg.roles)
    $canSign = ('root' -in $roles) -or ('intermediate' -in $roles)
    if ($canSign -and $subordinates.Count -eq 0) {
        $tier = if ('root' -in $roles) { 'root' } else { 'intermediate' }
        $caDir = Get-CADir -Tier $tier -Config $cfg
        $indexFile = "$caDir/db/index.txt"
        if (Test-Path $indexFile) {
            $lines = Get-Content $indexFile | Where-Object { $_.Trim() -ne '' }
            $backfilled = @()
            foreach ($line in $lines) {
                # Format: Status\tExpiry\t[Revocation]\tSerial\tunknown\tSubject
                $parts = $line -split "`t"
                if ($parts.Count -ge 6) {
                    $status = switch ($parts[0]) { 'V' { 'active' } 'R' { 'revoked' } default { 'expired' } }
                    $serial = $parts[3]
                    $subject = $parts[5]
                    $cn = if ($subject -match '/CN=([^/]+)') { $Matches[1] } else { $subject }
                    $backfilled += [PSCustomObject]@{
                        serial      = $serial
                        subject     = $subject
                        cn          = $cn
                        fingerprint = $null
                        notAfter    = $parts[1]
                        signedAt    = $null
                        status      = $status
                    }
                }
            }
            if ($backfilled.Count -gt 0) {
                $subordinates = $backfilled
                # Persist so we don't re-scan every time
                if (-not ($cfg.PSObject.Properties.Name -contains 'subordinates')) {
                    $cfg | Add-Member -NotePropertyName 'subordinates' -NotePropertyValue @()
                }
                $cfg.subordinates = $backfilled
                Save-InstanceConfig -Config $cfg
            }
        }
    }

    Write-PodeJsonResponse -Value @{
        self         = $selfInfo
        parent       = $parentInfo
        ancestors    = $ancestors
        subordinates = $subordinates
    }
}

Add-PodeRoute -Method 'Post' -Path '/api/subordinates/evict' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Node not configured.' }
        return
    }

    $body = $WebEvent.Data
    $serial = $body.serial
    $reason = $body.reason ?? 'cessationOfOperation'

    if (-not $serial) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Serial number is required.' }
        return
    }

    # Find subordinate in tracking
    if (-not ($cfg.PSObject.Properties.Name -contains 'subordinates')) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = 'No subordinates tracked.' }
        return
    }

    $sub = $cfg.subordinates | Where-Object { $_.serial -eq $serial } | Select-Object -First 1
    if (-not $sub) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = "No subordinate with serial $serial found." }
        return
    }

    if ($sub.status -eq 'revoked') {
        Write-PodeJsonResponse -Value @{
            success = $true
            message = 'Subordinate was already revoked.'
            serial  = $serial
        }
        return
    }

    # Determine CA directory and config
    $roles = @($cfg.roles)
    $tier = if ('root' -in $roles) { 'root' }
            elseif ('intermediate' -in $roles) { 'intermediate' }
            else { 'issuing' }
    $caDir = Get-CADir -Tier $tier -Config $cfg
    $configPath = Get-ActiveConfigPath -Tier $tier -Config $cfg
    $secretFile = Get-SecretFile -Config $cfg

    try {
        # Find the issued cert file — OpenSSL stores them in the issued/ dir
        # The serial is hex; the file is typically $serial.pem
        $serialHex = $serial.ToUpper()
        $issuedCert = Get-ChildItem "$caDir/issued" -Filter "*.pem" -ErrorAction SilentlyContinue |
            Where-Object {
                $content = Get-Content $_.FullName -Raw
                $content -match $serialHex
            } | Select-Object -First 1

        if (-not $issuedCert) {
            # Try the serial as filename directly
            $tryPath = "$caDir/issued/$serialHex.pem"
            if (Test-Path $tryPath) { $issuedCert = Get-Item $tryPath }
        }

        if (-not $issuedCert) {
            throw "Cannot find issued certificate for serial $serial in $caDir/issued/"
        }

        # Revoke the certificate
        Revoke-Certificate -CertPath $issuedCert.FullName `
            -ConfigPath $configPath -SecretFile $secretFile -Reason $reason

        # Regenerate CRL
        New-CRL -ConfigPath $configPath -SecretFile $secretFile `
            -CrlPemPath "$caDir/crl/ca.crl.pem" -CrlDerPath "$caDir/crl/ca.crl"

        # Update tracking
        $sub.status = 'revoked'
        $sub | Add-Member -NotePropertyName 'revokedAt' -NotePropertyValue (Get-Date -Format 'o') -Force
        $sub | Add-Member -NotePropertyName 'reason' -NotePropertyValue $reason -Force
        Save-InstanceConfig -Config $cfg

        Write-Log -Category 'topology' -Message " Evicted subordinate: $($sub.cn) (serial: $serial)"

        Write-PodeJsonResponse -Value @{
            success   = $true
            serial    = $serial
            cn        = $sub.cn
            reason    = $reason
            revokedAt = $sub.revokedAt
            message   = "Subordinate '$($sub.cn)' has been revoked."
        }
    } catch {
        Write-ErrorResponse -Message $_.Exception.Message
    }
}
