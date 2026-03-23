# =============================================================================
#  Root CA  ·  POST /api/sign-csr — Sign subordinate CA CSRs
#  CRL endpoints for the root tier
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Post' -Path '/api/sign-csr' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $body = $WebEvent.Data
    $cfg = Get-InstanceConfig
    $caDir = Get-CADir -Tier 'root' -Config $cfg
    $configPath = Get-ActiveConfigPath -Tier 'root' -Config $cfg
    $secretFile = Get-SecretFile -Config $cfg
    $certPath = "$caDir/certs/ca.crt"

    if (-not (Test-Path $certPath)) {
        Set-PodeResponseStatus -Code 503
        Write-PodeJsonResponse -Value @{ error = 'Root CA not initialized.' }
        return
    }

    $csrPEM     = $body.csr
    $extProfile = $body.profile ?? 'intermediate_ca_ext'
    $days       = [int]($body.days ?? 5475)

    if (-not $csrPEM -or -not ($csrPEM -match 'CERTIFICATE REQUEST')) {
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
        Write-ErrorResponse -Message $_.Exception.Message
    }
}

# ── CRL Endpoints (Root tier) ────────────────────────────────────────────────
Add-PodeRoute -Method 'Post' -Path '/api/crl/regenerate' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    $caDir = Get-CADir -Tier 'root' -Config $cfg
    $configPath = Get-ActiveConfigPath -Tier 'root' -Config $cfg
    $secretFile = Get-SecretFile -Config $cfg

    try {
        New-CRL -ConfigPath $configPath -SecretFile $secretFile `
            -CrlPemPath "$caDir/crl/ca.crl.pem" -CrlDerPath "$caDir/crl/ca.crl"
        Write-PodeJsonResponse -Value @{ success = $true; timestamp = (Get-Date -Format 'o') }
    } catch { Write-ErrorResponse -Message $_.Exception.Message }
}

Add-PodeRoute -Method 'Get' -Path '/api/crl/info' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    # Find the best CRL (issuing first, then intermediate, then root)
    $caDir = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        if (Test-Path "$d/crl/ca.crl.pem") { $caDir = $d; break }
    }
    if (-not $caDir) {
        Write-PodeJsonResponse -Value @{ error = 'CRL not yet generated.' }
        return
    }
    $crlPath = "$caDir/crl/ca.crl.pem"
    $text = (& openssl crl -in $crlPath -noout -text 2>&1) -join "`n"
    $lastUpdate = if ($text -match 'Last Update: (.+)') { $Matches[1].Trim() } else { '' }
    $nextUpdate = if ($text -match 'Next Update: (.+)') { $Matches[1].Trim() } else { '' }
    $crlNumber  = (Get-Content "$caDir/db/crlnumber" -ErrorAction SilentlyContinue)
    $entries    = if ($text -match 'No Revoked Certificates') { 0 } else { ([regex]::Matches($text, 'Serial Number:')).Count }
    Write-PodeJsonResponse -Value @{
        lastGenerated = $lastUpdate; nextUpdate = $nextUpdate
        entries = $entries; crlNumber = $crlNumber
    }
}

Add-PodeRoute -Method 'Get' -Path '/api/crl/pem' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    $caDir = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        if (Test-Path "$d/crl/ca.crl.pem") { $caDir = $d; break }
    }
    $p = "$caDir/crl/ca.crl.pem"
    if ($p -and (Test-Path $p)) { Write-PodeFileResponse -Path $p -ContentType 'application/x-pem-file' -Attachment -DownloadName 'ca.crl.pem' }
    else { Set-PodeResponseStatus -Code 404; Write-PodeJsonResponse -Value @{ error = 'CRL not found' } }
}

Add-PodeRoute -Method 'Get' -Path '/api/crl/der' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    $caDir = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        if (Test-Path "$d/crl/ca.crl" ) { $caDir = $d; break }
    }
    $p = "$caDir/crl/ca.crl"
    if ($p -and (Test-Path $p)) { Write-PodeFileResponse -Path $p -ContentType 'application/pkix-crl' -Attachment -DownloadName 'ca.crl' }
    else { Set-PodeResponseStatus -Code 404; Write-PodeJsonResponse -Value @{ error = 'CRL not found' } }
}
