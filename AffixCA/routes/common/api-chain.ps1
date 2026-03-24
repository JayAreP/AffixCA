# =============================================================================
#  Common  ·  Chain export endpoints
#  GET /api/chain            — Full trust chain PEM
#  GET /api/chain/download   — Download chain as PEM or PKCS#7
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/chain' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Set-PodeResponseStatus -Code 503
        Write-PodeJsonResponse -Value @{ error = 'CA not initialized.' }
        return
    }

    try {
        $chainPEM = Build-FullChainPEM -Config $cfg
        if ([string]::IsNullOrWhiteSpace($chainPEM)) {
            Write-PodeJsonResponse -Value @{ chain = ''; certs = @(); count = 0 }
            return
        }

        # Parse each cert in the chain
        $certs = @()
        $pemBlocks = [regex]::Matches($chainPEM, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
        foreach ($block in $pemBlocks) {
            $tmpFile = "/tmp/chain-parse-$([System.Guid]::NewGuid().ToString('N')).crt"
            $block.Value | Set-Content $tmpFile
            try {
                $ci = Get-CertInfo -CertPath $tmpFile
                $cn = ($ci.subject -split ',\s*' | Where-Object { $_ -match '^\s*CN\s*=' } | Select-Object -First 1) -replace '^\s*CN\s*=\s*', ''
                $certs += @{
                    cn          = $cn.Trim()
                    subject     = $ci.subject
                    serial      = $ci.serial
                    notBefore   = $ci.notBefore
                    notAfter    = $ci.notAfter
                    fingerprint = $ci.fingerprint
                    daysLeft    = $ci.daysUntilExp
                }
            } finally {
                Remove-Item $tmpFile -ErrorAction SilentlyContinue
            }
        }

        Write-PodeJsonResponse -Value @{
            chain = $chainPEM
            certs = $certs
            count = $certs.Count
        }
    } catch {
        Write-ErrorResponse -Message $_.Exception.Message
    }
}

Add-PodeRoute -Method 'Get' -Path '/api/chain/download' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Set-PodeResponseStatus -Code 503
        Write-PodeJsonResponse -Value @{ error = 'CA not initialized.' }
        return
    }

    $format = $WebEvent.Query['format'] ?? 'pem'
    $chainPEM = Build-FullChainPEM -Config $cfg

    if ([string]::IsNullOrWhiteSpace($chainPEM)) {
        Set-PodeResponseStatus -Code 404
        Write-PodeJsonResponse -Value @{ error = 'No chain available.' }
        return
    }

    $caName = ($cfg.caName ?? 'affix-ca') -replace '[^a-zA-Z0-9_-]', '-'
    $tmpFile = "/tmp/chain-$([System.Guid]::NewGuid().ToString('N'))"

    if ($format -eq 'p7b') {
        $pemFile = "$tmpFile.pem"
        $p7bFile = "$tmpFile.p7b"
        $chainPEM | Set-Content $pemFile
        & openssl crl2pkcs7 -nocrl -certfile $pemFile -outform DER -out $p7bFile 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $p7bFile)) {
            $bytes = [System.IO.File]::ReadAllBytes($p7bFile)
            Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"$caName-chain.p7b`""
            Write-PodeTextResponse -Bytes $bytes -ContentType 'application/x-pkcs7-certificates'
        } else {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = 'PKCS#7 conversion failed.' }
        }
        Remove-Item $pemFile, $p7bFile -ErrorAction SilentlyContinue
    } else {
        Add-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=`"$caName-chain.pem`""
        Write-PodeTextResponse -Value $chainPEM -ContentType 'application/x-pem-file'
    }
}

Add-PodeRoute -Method 'Post' -Path '/api/chain/refresh' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Not configured.' }
        return
    }
    if (-not $cfg.parentUrl) {
        Write-PodeJsonResponse -Value @{ success = $true; message = 'No parent — this is a root CA. No chain to refresh.' }
        return
    }
    try {
        Write-Log -Category 'admin' -Message "Refreshing chain from parent: $($cfg.parentUrl)"
        $parentChain = Invoke-RestMethod -Uri "$($cfg.parentUrl)/api/chain" `
            -TimeoutSec 10 -SkipCertificateCheck
        if ($parentChain.chain) {
            $chainDir = '/ca/chain'
            if (-not (Test-Path $chainDir)) { New-Item -ItemType Directory -Path $chainDir -Force | Out-Null }
            $parentChain.chain | Set-Content "$chainDir/chain.pem" -Force
            Write-Log -Category 'admin' -Message "Chain refreshed: $($parentChain.count) certs from parent"
            Write-PodeJsonResponse -Value @{
                success = $true
                message = "Chain refreshed from parent ($($parentChain.count) certs)."
                count   = $parentChain.count
            }
        } else {
            Write-PodeJsonResponse -Value @{ success = $false; error = 'Parent returned empty chain.' }
        }
    } catch {
        Write-Log -Category 'admin' -Level 'error' -Message "Chain refresh failed: $($_.Exception.Message)"
        Set-PodeResponseStatus -Code 500
        Write-PodeJsonResponse -Value @{ success = $false; error = $_.Exception.Message }
    }
}
