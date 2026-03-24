# =============================================================================
#  Intermediate CA  ·  POST /api/sign-csr — Sign issuing CA CSRs
#  Used in distributed mode when this instance serves the intermediate role.
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Post' -Path '/api/sign-csr' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    Write-Log -Category 'signing' -Message "Intermediate sign-csr: request received"
    $body = $WebEvent.Data
    $cfg = Get-InstanceConfig
    $caDir = Get-CADir -Tier 'intermediate' -Config $cfg
    $configPath = Get-ActiveConfigPath -Tier 'intermediate' -Config $cfg
    $secretFile = Get-SecretFile -Config $cfg
    $certPath = "$caDir/certs/ca.crt"
    Write-Log -Category 'signing' -Message "Intermediate sign-csr: caDir=$caDir | configPath=$configPath | certExists=$(Test-Path $certPath)"

    if (-not (Test-Path $certPath)) {
        Write-Log -Category 'signing' -Level 'error' -Message "Intermediate sign-csr: CA cert not found"
        Set-PodeResponseStatus -Code 503
        Write-PodeJsonResponse -Value @{ error = 'Intermediate CA not initialized.' }
        return
    }

    $csrPEM     = $body.csr
    $extProfile = $body.profile ?? 'issuing_ca_ext'
    $days       = [int]($body.days ?? 3652)
    Write-Log -Category 'signing' -Message "Intermediate sign-csr: profile=$extProfile | days=$days | CSR length=$($csrPEM.Length)"

    if (-not $csrPEM -or -not ($csrPEM -match 'CERTIFICATE REQUEST')) {
        Write-Log -Category 'signing' -Level 'error' -Message "Intermediate sign-csr: Invalid CSR"
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Invalid or missing CSR.' }
        return
    }

    try {
        $guid = [System.Guid]::NewGuid().ToString()
        $csrFile  = "/tmp/subordinate-$guid.csr"
        $certFile = "/tmp/subordinate-$guid.crt"
        $csrPEM | Set-Content $csrFile

        Invoke-SignCSR -CsrPath $csrFile -CertPath $certFile `
            -ConfigPath $configPath -ExtSection $extProfile `
            -SecretFile $secretFile -Days $days

        New-CRL -ConfigPath $configPath -SecretFile $secretFile `
            -CrlPemPath "$caDir/crl/ca.crl.pem" -CrlDerPath "$caDir/crl/ca.crl"

        $certInfo = Get-CertInfo -CertPath $certFile

        # Track subordinate in config
        if (-not ($cfg.PSObject.Properties.Name -contains 'subordinates')) {
            $cfg | Add-Member -NotePropertyName 'subordinates' -NotePropertyValue @()
        }
        $cn = if ($certInfo.subject -match 'CN\s*=\s*([^,/]+)') { $Matches[1].Trim() } else { $certInfo.subject }
        $cfg.subordinates = @($cfg.subordinates) + @([PSCustomObject]@{
            serial      = $certInfo.serial
            subject     = $certInfo.subject
            cn          = $cn
            fingerprint = $certInfo.fingerprint
            notAfter    = $certInfo.notAfter
            signedAt    = (Get-Date -Format 'o')
            profile     = $extProfile
            status      = 'active'
        })
        Save-InstanceConfig -Config $cfg
        Write-Log -Category 'signing' -Message "Intermediate signed subordinate: $cn (serial=$($certInfo.serial))"

        Write-PodeJsonResponse -Value @{
            success     = $true
            serial      = $certInfo.serial
            subject     = $certInfo.subject
            notBefore   = $certInfo.notBefore
            notAfter    = $certInfo.notAfter
            fingerprint = $certInfo.fingerprint
            certificate = $certInfo.pem
        }

        Remove-Item $csrFile, $certFile -ErrorAction SilentlyContinue
    } catch {
        Write-Log -Category 'signing' -Level 'error' -Message "Intermediate sign-csr failed: $($_.Exception.Message)"
        Write-ErrorResponse -Message $_.Exception.Message
    }
}
