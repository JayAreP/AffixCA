# =============================================================================
#  Setup  ·  Wizard API endpoints
#  POST /api/setup/init        — Initialize the CA (standalone or distributed)
#  POST /api/setup/test-parent — Test connectivity to a parent CA
#  GET  /api/setup/status      — Check if setup is complete
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/setup/status' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    $cfg = Get-InstanceConfig
    Write-PodeJsonResponse -Value @{
        configured = ($null -ne $cfg)
        timestamp  = (Get-Date -Format 'o')
    }
}

Add-PodeRoute -Method 'Post' -Path '/api/setup/test-parent' -ScriptBlock {
    $body = $WebEvent.Data
    $parentUrl  = $body.parentUrl
    $parentUser = $body.parentUser
    $parentPass = $body.parentPass

    if ([string]::IsNullOrWhiteSpace($parentUrl)) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'parentUrl is required.' }
        return
    }
    if ([string]::IsNullOrWhiteSpace($parentUser) -or [string]::IsNullOrWhiteSpace($parentPass)) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'Parent CA credentials are required.' }
        return
    }

    try {
        # Health endpoint is public — no auth needed
        $health = Invoke-RestMethod -Uri "$parentUrl/api/health" -TimeoutSec 5 -SkipCertificateCheck

        # Authenticate against parent CA to get a Bearer token
        $loginBody = @{ username = $parentUser; password = $parentPass } | ConvertTo-Json
        $loginResult = Invoke-RestMethod -Uri "$parentUrl/api/auth/login" `
            -Method Post -ContentType 'application/json' -Body $loginBody `
            -TimeoutSec 5 -SkipCertificateCheck

        if (-not $loginResult.success -or -not $loginResult.token) {
            Write-PodeJsonResponse -Value @{
                success = $false
                error   = "Authentication failed on parent CA: $($loginResult.message ?? 'invalid credentials')"
            }
            return
        }

        $authHeaders = @{ Authorization = "Bearer $($loginResult.token)" }

        # Status endpoint requires auth
        $status = Invoke-RestMethod -Uri "$parentUrl/api/status" -TimeoutSec 5 `
            -SkipCertificateCheck -Headers $authHeaders

        Write-PodeJsonResponse -Value @{
            success     = $true
            initialized = $health.initialized
            caName      = $status.caName
            roles       = $status.roles
            subject     = $status.caSubject
        }
    } catch {
        Write-PodeJsonResponse -Value @{
            success = $false
            error   = "Cannot reach parent CA: $($_.Exception.Message)"
        }
    }
}

Add-PodeRoute -Method 'Post' -Path '/api/setup/init' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $existing = Get-InstanceConfig
    if ($existing) {
        Set-PodeResponseStatus -Code 409
        Write-PodeJsonResponse -Value @{ error = 'CA is already configured.' }
        return
    }

    $body = $WebEvent.Data

    try {
        $mode       = $body.mode ?? 'standalone'
        $roles      = @($body.roles ?? @('root', 'intermediate', 'issuing'))
        $subj       = $body.subject ?? @{}
        $keyAlgo    = $body.keyAlgo ?? 'rsa'
        $keyParam   = $body.keyParam ?? '4096'
        $days       = [int]($body.days ?? 10957)
        $crlDays    = [int]($body.crlDays ?? 3650)
        $cdpUrl        = $body.cdpUrl ?? ''
        $aiaUrl        = $body.aiaUrl ?? ''
        $ocspUrl       = $body.ocspUrl ?? ''
        $templates     = @($body.templates ?? @('tls-server', 'tls-client'))
        $secretFile    = $env:CA_SECRET_FILE ?? '/run/secrets/ca_pass'
        $adminPassword = $body.adminPassword

        if ($mode -eq 'standalone') {
            # Full standalone ceremony: Root → Intermediate → Issuing
            $result = Initialize-StandaloneCA `
                -Subject @{
                    c  = $subj.c ?? 'US'
                    st = $subj.st
                    l  = $subj.l
                    o  = $subj.o ?? 'Example'
                    cn = $subj.cn ?? "$($subj.o ?? 'Example') Root CA"
                } `
                -KeyAlgo $keyAlgo -KeyParam $keyParam `
                -RootDays $days -CrlDays $crlDays `
                -CdpUrl $cdpUrl -AiaUrl $aiaUrl -OcspUrl $ocspUrl `
                -SecretFile $secretFile -Templates $templates

            # Set admin password if provided
            if ($adminPassword) {
                $store = Get-AuthStore
                $admin = $store.users | Where-Object { $_.username -eq 'admin' }
                if ($admin) {
                    $salt = New-Salt
                    $admin.salt = $salt
                    $admin.passwordHash = Get-PasswordHash -Password $adminPassword -Salt $salt
                    Save-AuthStore -Store $store
                }
            }

            Write-PodeJsonResponse -Value @{
                success = $result.success
                steps   = $result.steps
                mode    = 'standalone'
                roles   = @('root', 'intermediate', 'issuing')
                restart = $true
            }

            # Give the response time to flush before restarting
            Start-Sleep -Seconds 2
            Restart-PodeServer

        } elseif ('root' -in $roles) {
            # Distributed: Root CA only
            $caDir = '/ca'
            Initialize-CADirectories -CADir $caDir

            $rootSubject = @{
                c  = $subj.c ?? 'US'; st = $subj.st; l = $subj.l
                o  = $subj.o ?? 'Example'
                cn = $subj.cn ?? "$($subj.o ?? 'Example') Root CA"
            }

            $rootCfg = "$caDir/ca.cnf"
            New-PatchedConfig -TemplatePath '/app/config/openssl/root-ca.cnf' `
                -OutputPath $rootCfg -Subject $rootSubject `
                -CdpUrl $cdpUrl -AiaUrl $aiaUrl -OcspUrl $ocspUrl `
                -CrlDays $crlDays -CaSectionName 'root_ca'

            $keySize = if ($keyAlgo -eq 'rsa') { [int]$keyParam } else { 0 }
            $curve   = if ($keyAlgo -eq 'ecdsa') { $keyParam } else { 'P-384' }

            New-CAPrivateKey -KeyPath "$caDir/private/ca.key" -SecretFile $secretFile `
                -Algorithm $keyAlgo -KeySize $keySize -Curve $curve

            New-SelfSignedCACert -KeyPath "$caDir/private/ca.key" -CertPath "$caDir/certs/ca.crt" `
                -ConfigPath $rootCfg -SecretFile $secretFile -Days $days

            New-CRL -ConfigPath $rootCfg -SecretFile $secretFile `
                -CrlPemPath "$caDir/crl/ca.crl.pem" -CrlDerPath "$caDir/crl/ca.crl"

            $certInfo = Get-CertInfo -CertPath "$caDir/certs/ca.crt"

            $config = @{
                instanceId = [System.Guid]::NewGuid().ToString()
                roles      = @('root')
                standalone = $false
                caName     = $rootSubject.cn
                subject    = $rootSubject
                keyAlgo    = $keyAlgo; keyParam = $keyParam
                days       = $days; crlDays = $crlDays
                cdpUrl     = $cdpUrl; aiaUrl = $aiaUrl; ocspUrl = $ocspUrl
                templates  = @()
                createdAt  = (Get-Date -Format 'o')
            }
            Save-InstanceConfig -Config $config

            # Set admin password if provided
            if ($adminPassword) {
                $store = Get-AuthStore
                $admin = $store.users | Where-Object { $_.username -eq 'admin' }
                if ($admin) {
                    $salt = New-Salt
                    $admin.salt = $salt
                    $admin.passwordHash = Get-PasswordHash -Password $adminPassword -Salt $salt
                    Save-AuthStore -Store $store
                }
            }

            Write-PodeJsonResponse -Value @{
                success     = $true
                mode        = 'distributed'
                roles       = @('root')
                serial      = $certInfo.serial
                subject     = $certInfo.subject
                fingerprint = $certInfo.fingerprint
                certificate = $certInfo.pem
                restart     = $true
            }

            Restart-PodeServer

        } else {
            # Distributed: non-root role (intermediate or issuing)
            $parentUrl  = $body.parentUrl
            $parentUser = $body.parentUser
            $parentPass = $body.parentPass

            if ([string]::IsNullOrWhiteSpace($parentUrl)) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = 'parentUrl is required for non-root roles.' }
                return
            }
            if ([string]::IsNullOrWhiteSpace($parentUser) -or [string]::IsNullOrWhiteSpace($parentPass)) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = 'Parent CA credentials are required for non-root roles.' }
                return
            }

            # Authenticate against parent CA
            $loginBody = @{ username = $parentUser; password = $parentPass } | ConvertTo-Json
            $loginResult = Invoke-RestMethod -Uri "$parentUrl/api/auth/login" `
                -Method Post -ContentType 'application/json' -Body $loginBody `
                -TimeoutSec 10 -SkipCertificateCheck

            if (-not $loginResult.success -or -not $loginResult.token) {
                Set-PodeResponseStatus -Code 401
                Write-PodeJsonResponse -Value @{
                    error = "Failed to authenticate with parent CA: $($loginResult.message ?? 'invalid credentials')"
                }
                return
            }

            $parentAuthHeaders = @{ Authorization = "Bearer $($loginResult.token)" }

            $role = $roles[0]
            $caDir = '/ca'
            Initialize-CADirectories -CADir $caDir

            $configMap = @{
                intermediate = 'intermediate-ca'
                issuing      = 'issuing-ca'
            }
            $templateCnf = "/app/config/openssl/$($configMap[$role]).cnf"
            $caCfg = "$caDir/ca.cnf"

            $roleSubject = @{
                c  = $subj.c ?? 'US'; o = $subj.o ?? 'Example'
                cn = $subj.cn ?? "$($subj.o ?? 'Example') $role CA"
            }

            New-PatchedConfig -TemplatePath $templateCnf -OutputPath $caCfg `
                -Subject $roleSubject -CdpUrl $cdpUrl -AiaUrl $aiaUrl -OcspUrl $ocspUrl

            $keySize = if ($keyAlgo -eq 'rsa') { [int]$keyParam } else { 0 }
            $curve   = if ($keyAlgo -eq 'ecdsa') { $keyParam } else { 'P-384' }

            New-CAPrivateKey -KeyPath "$caDir/private/ca.key" -SecretFile $secretFile `
                -Algorithm $keyAlgo -KeySize $keySize -Curve $curve

            New-CACSR -KeyPath "$caDir/private/ca.key" -CsrPath "$caDir/csr/ca.csr" `
                -ConfigPath $caCfg -SecretFile $secretFile

            # Submit CSR to parent CA (authenticated)
            $csrPEM = Get-Content "$caDir/csr/ca.csr" -Raw
            $profile = if ($role -eq 'intermediate') { 'intermediate_ca_ext' } else { 'issuing_ca_ext' }
            $signDays = if ($role -eq 'intermediate') { 5475 } else { 3652 }

            $signBody = @{ csr = $csrPEM; profile = $profile; days = $signDays } | ConvertTo-Json -Depth 5
            $signResult = Invoke-RestMethod -Uri "$parentUrl/api/sign-csr" `
                -Method Post -ContentType 'application/json' -Body $signBody `
                -TimeoutSec 120 -SkipCertificateCheck -Headers $parentAuthHeaders

            if (-not $signResult.certificate) { throw "Parent CA failed to sign CSR" }

            # Install signed cert
            $signResult.certificate | Set-Content "$caDir/certs/ca.crt"

            # Get parent's chain and build ours
            try {
                $parentChain = Invoke-RestMethod -Uri "$parentUrl/api/chain" -TimeoutSec 10 `
                    -SkipCertificateCheck -Headers $parentAuthHeaders
                if ($parentChain.chain) {
                    $parentChain.chain | Set-Content "$caDir/chain/chain.pem"
                }
            } catch {
                # Parent chain not available — just save the parent cert
                if ($signResult.certificate) {
                    $signResult.certificate | Set-Content "$caDir/chain/chain.pem"
                }
            }

            # Generate CRL
            New-CRL -ConfigPath $caCfg -SecretFile $secretFile `
                -CrlPemPath "$caDir/crl/ca.crl.pem" -CrlDerPath "$caDir/crl/ca.crl"

            $certInfo = Get-CertInfo -CertPath "$caDir/certs/ca.crt"

            $config = @{
                instanceId = [System.Guid]::NewGuid().ToString()
                roles      = @($role)
                standalone = $false
                caName     = $roleSubject.cn
                subject    = $roleSubject
                keyAlgo    = $keyAlgo; keyParam = $keyParam
                parentUrl  = $parentUrl
                templates  = if ($role -eq 'issuing') { $templates } else { @() }
                createdAt  = (Get-Date -Format 'o')
            }
            Save-InstanceConfig -Config $config

            # Set admin password if provided
            if ($adminPassword) {
                $store = Get-AuthStore
                $admin = $store.users | Where-Object { $_.username -eq 'admin' }
                if ($admin) {
                    $salt = New-Salt
                    $admin.salt = $salt
                    $admin.passwordHash = Get-PasswordHash -Password $adminPassword -Salt $salt
                    Save-AuthStore -Store $store
                }
            }

            Write-PodeJsonResponse -Value @{
                success     = $true
                mode        = 'distributed'
                roles       = @($role)
                serial      = $certInfo.serial
                subject     = $certInfo.subject
                fingerprint = $certInfo.fingerprint
                restart     = $true
            }

            Restart-PodeServer
        }

    } catch {
        Write-PodeHost "[Setup] ERROR: $($_.Exception.Message)"
        Write-PodeHost "[Setup] STACK: $($_.ScriptStackTrace)"
        Set-PodeResponseStatus -Code 500
        Write-PodeJsonResponse -Value @{
            success = $false
            error   = $_.Exception.Message
        }
    }
}
