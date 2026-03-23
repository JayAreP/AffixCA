# =============================================================================
#  Common  ·  Web Server Certificate Management
#  GET  /api/webserver/cert       — Current cert info
#  POST /api/webserver/csr        — Generate a new CSR
#  POST /api/webserver/install    — Install a signed certificate
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

# ── GET current web server certificate info ──────────────────────────────────
Add-PodeRoute -Method 'Get' -Path '/api/webserver/cert' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $dir     = Get-WebCertDir
    $crtFile = "$dir/server.crt"
    $csrFile = "$dir/server.csr"

    if (-not (Test-Path $crtFile)) {
        Write-PodeJsonResponse -Value @{ hasCert = $false }
        return
    }

    try {
        $ci = Get-CertInfo -CertPath $crtFile
        $isSelfSigned = $ci.subject -eq $ci.issuer

        $result = @{
            hasCert     = $true
            selfSigned  = $isSelfSigned
            subject     = $ci.subject
            issuer      = $ci.issuer
            serial      = $ci.serial
            notBefore   = $ci.notBefore
            notAfter    = $ci.notAfter
            fingerprint = $ci.fingerprint
            daysLeft    = $ci.daysUntilExp
        }

        # Include pending CSR if one exists
        if (Test-Path $csrFile) {
            $result.pendingCsr = Get-Content $csrFile -Raw
        }

        Write-PodeJsonResponse -Value $result
    } catch {
        Write-PodeJsonResponse -Value @{
            hasCert = $true
            error   = $_.Exception.Message
        }
    }
}

# ── POST generate a new CSR ──────────────────────────────────────────────────
Add-PodeRoute -Method 'Post' -Path '/api/webserver/csr' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $body = $WebEvent.Data
    $cn   = $body.commonName ?? 'Affix/CA Web Server'
    $sans = $body.sans ?? ''

    try {
        $csrPem = New-WebServerCSR -CommonName $cn -SANs $sans
        Write-PodeJsonResponse -Value @{
            success = $true
            csr     = $csrPem
        }
    } catch {
        Set-PodeResponseStatus -Code 500
        Write-PodeJsonResponse -Value @{
            success = $false
            error   = $_.Exception.Message
        }
    }
}

# ── POST install a signed certificate ────────────────────────────────────────
Add-PodeRoute -Method 'Post' -Path '/api/webserver/install' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $body    = $WebEvent.Data
    $certPem = $body.certificate

    if ([string]::IsNullOrWhiteSpace($certPem)) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Certificate PEM is required.' }
        return
    }

    try {
        Install-WebServerCert -CertPEM $certPem

        # Clean up the CSR file since it's been fulfilled
        $csrFile = "$(Get-WebCertDir)/server.csr"
        Remove-Item $csrFile -ErrorAction SilentlyContinue

        Write-PodeJsonResponse -Value @{
            success = $true
            message = 'Certificate installed. Restarting server...'
        }

        # Restart Pode to pick up the new certificate
        Restart-PodeServer
    } catch {
        Set-PodeResponseStatus -Code 500
        Write-PodeJsonResponse -Value @{
            success = $false
            error   = $_.Exception.Message
        }
    }
}
