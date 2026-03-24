# =============================================================================
#  Issuing CA  ·  POST /api/issue — Template-driven certificate issuance
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Post' -Path '/api/issue' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $body    = $WebEvent.Data
    Write-Log -Category 'certificates' -Message "Issue request: template=$($body.template) cn=$($body.cn)"
    $cfg     = Get-InstanceConfig
    $caDir   = Get-CADir -Tier 'issuing' -Config $cfg
    $cfgPath = Get-ActiveConfigPath -Tier 'issuing' -Config $cfg
    $secret  = Get-SecretFile -Config $cfg

    if (-not (Test-Path "$caDir/certs/ca.crt")) {
        Set-PodeResponseStatus -Code 503
        Write-PodeJsonResponse -Value @{ error = 'Issuing CA not initialized.' }
        return
    }

    $templateId  = ($body.template ?? $body.profile ?? 'tls-server').ToLower().Trim()
    $days        = [int]($body.days ?? 365)
    $keyAlgo     = ($body.keyAlgo ?? 'ecdsa').ToLower()
    $keyParam    = $body.keyParam ?? 'P-256'
    $externalCSR = $body.csr
    $guid        = [System.Guid]::NewGuid().ToString('N')

    # Load template
    $templates = Get-CertTemplates -EnabledTemplates @($cfg.templates ?? @())
    $template = $templates | Where-Object { $_.id -eq $templateId } | Select-Object -First 1
    if (-not $template) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = "Unknown template '$templateId'. Available: $($templates.id -join ', ')" }
        return
    }

    # Validate days
    $maxDays = [int]($template.maxDays ?? 825)
    if ($days -lt 1 -or $days -gt $maxDays) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = "days must be between 1 and $maxDays for template '$templateId'" }
        return
    }

    $tmpKey  = "/tmp/$guid.key"
    $tmpCSR  = "/tmp/$guid.csr"
    $tmpExt  = "/tmp/$guid.ext"
    $tmpCert = "/tmp/$guid.crt"

    try {
        # ── Step 1: Key + CSR ────────────────────────────────────────────────
        if ([string]::IsNullOrWhiteSpace($externalCSR)) {
            $subject = $body.subject
            if (-not $subject -or [string]::IsNullOrWhiteSpace($subject.cn)) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = 'subject.cn is required when not supplying a CSR' }
                return
            }
            $cn  = $subject.cn.Trim()
            $org = $subject.o  ?? ''
            $ou  = $subject.ou ?? ''
            $c   = $subject.c  ?? ''
            $dn  = "/CN=$cn"
            if ($org) { $dn += "/O=$org" }
            if ($ou)  { $dn += "/OU=$ou" }
            if ($c)   { $dn += "/C=$c" }

            New-EEPrivateKey -KeyPath $tmpKey -Algorithm $keyAlgo `
                -KeySize ([int]($keyParam -replace '\D', '' )) -Curve $keyParam

            & openssl req -new -key $tmpKey -subj $dn -out $tmpCSR 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "CSR generation failed" }
        } else {
            if (-not $template.allowCSR) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = "Template '$templateId' does not accept external CSRs." }
                return
            }
            $externalCSR | Set-Content $tmpCSR
            $verify = & openssl req -in $tmpCSR -noout 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Invalid CSR PEM: $verify" }
        }

        # ── Step 2: Build SAN entries ────────────────────────────────────────
        $sans = @()
        if ($body.san -and $body.san.Count -gt 0) {
            foreach ($entry in $body.san) {
                $e = $entry.ToString().Trim()
                if ($e -match '^(DNS:|IP:|email:|URI:)') { $sans += $e }
                elseif ($e -match '^\d{1,3}(\.\d{1,3}){3}$') { $sans += "IP:$e" }
                elseif ($e -match '@') { $sans += "email:$e" }
                elseif ($e -match '^https?://') { $sans += "URI:$e" }
                else { $sans += "DNS:$e" }
            }
        } elseif ($template.autoSanFromCN -and -not [string]::IsNullOrWhiteSpace($body.subject.cn)) {
            $sans += "DNS:$($body.subject.cn.Trim())"
        }

        # ── Step 3: Build extension file from template ───────────────────────
        $extSection = New-DynamicExtFile -Template $template -SANEntries $sans -OutputPath $tmpExt

        # ── Step 4: Sign ─────────────────────────────────────────────────────
        Invoke-SignCSR -CsrPath $tmpCSR -CertPath $tmpCert `
            -ConfigPath $cfgPath -ExtFile $tmpExt -ExtSection $extSection `
            -SecretFile $secret -Days $days

        $ci = Get-CertInfo -CertPath $tmpCert
        $serial = $ci.serial

        # ── Step 5: Save to issued store ─────────────────────────────────────
        Copy-Item $tmpCert -Destination "$caDir/issued/$serial.pem" -Force
        if (Test-Path $tmpKey) {
            Copy-Item $tmpKey -Destination "$caDir/issued/$serial.key" -Force
            & chmod 600 "$caDir/issued/$serial.key" 2>&1 | Out-Null
        }

        # ── Step 6: Response ─────────────────────────────────────────────────
        $certPem  = Get-Content $tmpCert -Raw
        $keyPem   = if (Test-Path $tmpKey) { Get-Content $tmpKey -Raw } else { $null }
        $chainPem = Get-ChainPEM -CADir $caDir

        $response = @{
            serial      = $serial
            certificate = $certPem
            chain       = $chainPem
            notAfter    = $ci.notAfter
            notBefore   = $ci.notBefore
            subject     = $ci.subject
            template    = $templateId
        }
        if ($keyPem) { $response.privateKey = $keyPem }
        Write-Log -Category 'certificates' -Message "Issued cert: serial=$serial template=$templateId subject=$($ci.subject)"
        Write-PodeJsonResponse -Value $response

    } catch {
        Write-Log -Category 'certificates' -Level 'error' -Message "Issue failed: $($_.Exception.Message)"
        Set-PodeResponseStatus -Code 500
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message }
    } finally {
        Remove-Item $tmpKey, $tmpCSR, $tmpExt, $tmpCert -ErrorAction SilentlyContinue
    }
}
