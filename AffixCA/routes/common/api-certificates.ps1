# =============================================================================
#  Common  ·  Certificate management endpoints
#  GET  /api/certificates             — List all issued certificates
#  GET  /api/certificates/:serial     — Get certificate metadata
#  GET  /api/certificates/:serial/pem — Download PEM
#  POST /api/certificates/:serial/revoke  — Revoke a certificate
#  POST /api/certificates/:serial/pkcs12  — Export PKCS#12 bundle
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/certificates' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    try {
        $cfg = Get-InstanceConfig
        $caDir = Get-CADir -Tier 'issuing' -Config $cfg
        # Fall back to root/intermediate if no issuing role
        if (-not (Test-Path "$caDir/db/index.txt")) {
            foreach ($t in @('intermediate', 'root')) {
                $d = Get-CADir -Tier $t -Config $cfg
                if (Test-Path "$d/db/index.txt") { $caDir = $d; break }
            }
        }
        $certs = Get-CertList -CADir $caDir
        Write-PodeJsonResponse -Value @{
            certificates = $certs
            count        = $certs.Count
            timestamp    = (Get-Date -Format 'o')
        }
    } catch {
        Write-ErrorResponse -Message $_.Exception.Message
    }
}

Add-PodeRoute -Method 'Get' -Path '/api/certificates/:serial' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $serial = $WebEvent.Parameters['serial'] -replace '[^0-9A-Fa-f]', ''
    $cfg = Get-InstanceConfig
    # Search all tiers for the cert
    $certFile = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        $f = "$d/issued/$serial.pem"
        if (Test-Path $f) { $certFile = $f; break }
    }
    if (-not $certFile) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = "Certificate $serial not found." }
        return
    }
    try {
        $info = Get-CertInfo -CertPath $certFile
        Write-PodeJsonResponse -Value $info
    } catch { Write-ErrorResponse -Message $_.Exception.Message }
}

Add-PodeRoute -Method 'Get' -Path '/api/certificates/:serial/pem' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $serial = $WebEvent.Parameters['serial'] -replace '[^0-9A-Fa-f]', ''
    $cfg = Get-InstanceConfig
    $certFile = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        $f = "$d/issued/$serial.pem"
        if (Test-Path $f) { $certFile = $f; break }
    }
    if (-not $certFile) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = "Certificate $serial not found." }
        return
    }
    Write-PodeJsonResponse -Value @{ pem = (Get-Content $certFile -Raw) }
}

Add-PodeRoute -Method 'Post' -Path '/api/certificates/:serial/revoke' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $serial = $WebEvent.Parameters['serial'] -replace '[^0-9A-Fa-f]', ''
    $cfg = Get-InstanceConfig

    # Find which tier has this cert
    $certFile = $null; $caDir = $null; $configPath = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        $f = "$d/issued/$serial.pem"
        if (Test-Path $f) {
            $certFile = $f; $caDir = $d
            $configPath = Get-ActiveConfigPath -Tier $t -Config $cfg
            break
        }
    }
    if (-not $certFile) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = "Certificate $serial not found." }
        return
    }

    $secretFile = Get-SecretFile -Config $cfg
    $reason = $WebEvent.Data.reason ?? 'unspecified'
    $validReasons = @('unspecified','keyCompromise','CACompromise','affiliationChanged','superseded','cessationOfOperation','certificateHold')
    if ($reason -notin $validReasons) { $reason = 'unspecified' }

    try {
        Revoke-Certificate -CertPath $certFile -ConfigPath $configPath -SecretFile $secretFile -Reason $reason
        New-CRL -ConfigPath $configPath -SecretFile $secretFile `
            -CrlPemPath "$caDir/crl/ca.crl.pem" -CrlDerPath "$caDir/crl/ca.crl"
        Write-PodeJsonResponse -Value @{ success = $true; serial = $serial; reason = $reason; timestamp = (Get-Date -Format 'o') }
    } catch { Write-ErrorResponse -Message $_.Exception.Message }
}

Add-PodeRoute -Method 'Post' -Path '/api/certificates/:serial/pkcs12' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $serial = $WebEvent.Parameters['serial'] -replace '[^0-9A-Fa-f]', ''
    $cfg = Get-InstanceConfig

    $certFile = $null; $caDir = $null
    foreach ($t in @('issuing', 'intermediate', 'root')) {
        $d = Get-CADir -Tier $t -Config $cfg
        $f = "$d/issued/$serial.pem"
        if (Test-Path $f) { $certFile = $f; $caDir = $d; break }
    }

    $keyFile = "$caDir/issued/$serial.key"
    if (-not $certFile -or -not (Test-Path $keyFile)) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = "Certificate or key for $serial not found." }
        return
    }

    $password = $WebEvent.Data.password
    if (-not $password -or $password.Length -lt 4) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Password must be at least 4 characters.' }
        return
    }

    try {
        $guid = [System.Guid]::NewGuid().ToString()
        $p12Path = "/tmp/$guid.p12"
        $chain = Get-ChainPEM -CADir $caDir
        $chainFile = $null
        if ($chain) { $chainFile = "/tmp/$guid-chain.pem"; $chain | Set-Content $chainFile }

        New-PKCS12Bundle -CertPath $certFile -KeyPath $keyFile `
            -ChainPath ($chainFile ?? $certFile) -P12Path $p12Path `
            -FriendlyName $serial -P12Password $password

        $p12B64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p12Path))
        Remove-Item $p12Path -ErrorAction SilentlyContinue
        if ($chainFile) { Remove-Item $chainFile -ErrorAction SilentlyContinue }

        Write-PodeJsonResponse -Value @{ p12Base64 = $p12B64; serial = $serial }
    } catch { Write-ErrorResponse -Message $_.Exception.Message }
}
