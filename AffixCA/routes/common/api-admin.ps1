# =============================================================================
#  Common  ·  Administration API endpoints
#  POST /api/admin/decommission — Reset this node's role and return to setup
#  GET  /api/admin/info         — Get current node configuration details
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/admin/info' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Write-PodeJsonResponse -Value @{
            configured = $false
        }
        return
    }

    $info = @{
        configured  = $true
        instanceId  = $cfg.instanceId
        roles       = @($cfg.roles)
        standalone  = ($cfg.standalone -eq $true)
        caName      = $cfg.caName
        subject     = $cfg.subject
        keyAlgo     = $cfg.keyAlgo
        keyParam    = $cfg.keyParam
        parentUrl   = $cfg.parentUrl
        createdAt   = $cfg.createdAt
    }

    # Check CA cert details
    $caDir = '/ca'
    $certPath = "$caDir/certs/ca.crt"
    if (Test-Path $certPath) {
        try {
            $ci = Get-CertInfo -CertPath $certPath
            $info.serial      = $ci.serial
            $info.certSubject = $ci.subject
            $info.notBefore   = $ci.notBefore
            $info.notAfter    = $ci.notAfter
            $info.fingerprint = $ci.fingerprint
        } catch {}
    }

    Write-PodeJsonResponse -Value $info
}

Add-PodeRoute -Method 'Post' -Path '/api/admin/decommission' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $body = $WebEvent.Data
    $confirmText = $body.confirm

    $cfg = Get-InstanceConfig
    if (-not $cfg) {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{ error = 'This node is not configured. Nothing to decommission.' }
        return
    }

    # Require explicit confirmation
    if ($confirmText -ne 'DECOMMISSION') {
        Set-PodeResponseStatus -Code 400
        Write-PodeJsonResponse -Value @{
            error = 'Confirmation required. Send { "confirm": "DECOMMISSION" } to proceed.'
        }
        return
    }

    try {
        $roleName = ($cfg.roles -join ', ')
        $caName   = $cfg.caName

        Write-PodeHost "[Admin] Decommissioning node: $caName (roles: $roleName)"

        # Archive current config before removal
        $archiveDir = '/ca/archive'
        if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }

        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $configPath = '/ca/config.json'
        if (Test-Path $configPath) {
            Copy-Item $configPath "$archiveDir/config-$ts.json" -Force
        }

        # Remove CA operational files but preserve archive
        $dirsToClean = @('certs', 'crl', 'csr', 'db', 'newcerts', 'private', 'chain')
        foreach ($d in $dirsToClean) {
            $dirPath = "/ca/$d"
            if (Test-Path $dirPath) {
                Remove-Item "$dirPath/*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Remove config files
        Remove-Item '/ca/config.json' -Force -ErrorAction SilentlyContinue
        Remove-Item '/ca/ca.cnf' -Force -ErrorAction SilentlyContinue

        # Reset auth store (remove sessions but keep default structure)
        $authPath = '/ca/auth.json'
        if (Test-Path $authPath) {
            Remove-Item $authPath -Force -ErrorAction SilentlyContinue
        }

        Write-PodeJsonResponse -Value @{
            success = $true
            message = "Node '$caName' ($roleName) has been decommissioned. The server will restart into setup mode."
            archivedConfig = "$archiveDir/config-$ts.json"
        }

        Write-PodeHost "[Admin] Decommission complete. Restarting into setup wizard..."

        # Give response time to flush before restarting
        Start-Sleep -Seconds 2
        Restart-PodeServer

    } catch {
        Write-PodeHost "[Admin] Decommission ERROR: $($_.Exception.Message)"
        Set-PodeResponseStatus -Code 500
        Write-PodeJsonResponse -Value @{
            success = $false
            error   = $_.Exception.Message
        }
    }
}
