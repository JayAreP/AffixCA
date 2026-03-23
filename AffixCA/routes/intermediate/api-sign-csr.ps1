# =============================================================================
#  Intermediate CA  ·  POST /api/sign-csr — Sign issuing CA CSRs
#  Used in distributed mode when this instance serves the intermediate role.
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Post' -Path '/api/intermediate/sign-csr' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $body = $WebEvent.Data
    $cfg = Get-InstanceConfig
    $caDir = Get-CADir -Tier 'intermediate' -Config $cfg
    $configPath = Get-ActiveConfigPath -Tier 'intermediate' -Config $cfg
    $secretFile = Get-SecretFile -Config $cfg
    $certPath = "$caDir/certs/ca.crt"

    if (-not (Test-Path $certPath)) {
        Set-PodeResponseStatus -Code 503
        Write-PodeJsonResponse -Value @{ error = 'Intermediate CA not initialized.' }
        return
    }

    $csrPEM     = $body.csr
    $extProfile = $body.profile ?? 'issuing_ca_ext'
    $days       = [int]($body.days ?? 3652)

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
