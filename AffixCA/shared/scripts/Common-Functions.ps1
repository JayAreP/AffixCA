# =============================================================================
#  Common-Functions.ps1  ·  Shared PowerShell library for Affix/CA
# =============================================================================

#region ── Logging ─────────────────────────────────────────────────────────────

$script:LogFile = '/ca/logs/server.log'
$script:LogMaxBytes = 5 * 1024 * 1024   # 5 MB — rotate when exceeded

function Write-Log {
    <#
    .SYNOPSIS
        Structured logging to /ca/logs/server.log + Write-PodeHost for Docker logs.
        Categories: system, setup, admin, signing, topology, auth, certificates, errors
        Levels: info, warn, error, debug
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('system','setup','admin','signing','topology','auth','certificates','errors')]
        [string]$Category = 'system',
        [ValidateSet('info','warn','error','debug')]
        [string]$Level = 'info'
    )

    $entry = @{
        ts       = (Get-Date -Format 'o')
        level    = $Level
        category = $Category
        message  = $Message
    } | ConvertTo-Json -Compress

    # Ensure log directory exists
    $logDir = Split-Path $script:LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Rotate if oversized
    if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt $script:LogMaxBytes) {
        $rotated = "$($script:LogFile).1"
        if (Test-Path $rotated) { Remove-Item $rotated -Force }
        Rename-Item $script:LogFile $rotated -Force
    }

    # Append — use mutex to avoid partial writes from Pode runspaces
    try {
        [System.IO.File]::AppendAllText($script:LogFile, "$entry`n")
    } catch {
        # Last resort: skip file write if locked
    }

    # Also emit to Docker logs via Write-PodeHost (if inside Pode) or Write-Host
    $prefix = "[$($Category.ToUpper())] [$Level]"
    $logLine = "$prefix $Message"
    try { Write-PodeHost $logLine } catch { Write-Host $logLine }
}

function Get-LogEntries {
    <#
    .SYNOPSIS
        Read log entries, optionally filtering by category / level / since timestamp.
        Returns newest-first.
    #>
    param(
        [string[]]$Categories,
        [string[]]$Levels,
        [datetime]$Since,
        [int]$Limit = 500
    )

    $results = @()
    $files = @($script:LogFile)
    $rotated = "$($script:LogFile).1"
    if (Test-Path $rotated) { $files += $rotated }

    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        $lines = Get-Content $f
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                if ($Categories -and $Categories.Count -gt 0 -and $obj.category -notin $Categories) { continue }
                if ($Levels -and $Levels.Count -gt 0 -and $obj.level -notin $Levels) { continue }
                if ($Since -and [datetime]$obj.ts -lt $Since) { continue }
                $results += $obj
            } catch { continue }
        }
    }

    # Newest first, limited
    $results = $results | Sort-Object ts -Descending
    if ($Limit -gt 0 -and $results.Count -gt $Limit) {
        $results = $results[0..($Limit - 1)]
    }
    return $results
}

#endregion

#region ── Configuration ────────────────────────────────────────────────────────

function Get-InstanceConfig {
    param([string]$ConfigFile = '/ca/config.json')
    if (Test-Path $ConfigFile) {
        return Get-Content $ConfigFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-InstanceConfig {
    param([object]$Config, [string]$ConfigFile = '/ca/config.json')
    $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigFile
}

function Get-CADir {
    <#
    .SYNOPSIS
        Returns the data directory for a given tier.
        Standalone: /ca/root, /ca/intermediate, /ca/issuing
        Distributed: /ca
    #>
    param([string]$Tier, [object]$Config)
    if ($Config -and $Config.standalone -eq $true) {
        return "/ca/$Tier"
    }
    return '/ca'
}

function Get-ActiveConfigPath {
    <#
    .SYNOPSIS
        Returns the active OpenSSL config (volume-persisted if patched, else app default).
    #>
    param([string]$Tier = '', [object]$Config = $null)
    if ($Config -and $Config.standalone -eq $true -and $Tier) {
        $persisted = "/ca/$Tier/ca.cnf"
        if (Test-Path $persisted) { return $persisted }
        $roleMap = @{ root = 'root-ca'; intermediate = 'intermediate-ca'; issuing = 'issuing-ca' }
        return "/app/config/openssl/$($roleMap[$Tier]).cnf"
    }
    if (Test-Path '/ca/ca.cnf') { return '/ca/ca.cnf' }
    return '/app/config/openssl/root-ca.cnf'
}

function Get-SecretFile {
    param([string]$Tier = '', [object]$Config = $null)
    if ($Config -and $Config.standalone -eq $true) {
        return '/run/secrets/ca_pass'
    }
    return $env:CA_SECRET_FILE ?? '/run/secrets/ca_pass'
}

#endregion

#region ── Directory & Database Initialization ─────────────────────────────────

function Initialize-CADirectories {
    param([string]$CADir = '/ca')

    $dirs = @(
        "$CADir/certs", "$CADir/crl", "$CADir/issued",
        "$CADir/private", "$CADir/db", "$CADir/csr", "$CADir/chain"
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    & chmod 700 "$CADir/private"

    if (-not (Test-Path "$CADir/db/index.txt"))      { '' | Set-Content "$CADir/db/index.txt" -NoNewline }
    if (-not (Test-Path "$CADir/db/index.txt.attr"))  { 'unique_subject = no' | Set-Content "$CADir/db/index.txt.attr" }
    if (-not (Test-Path "$CADir/db/serial"))          { '01' | Set-Content "$CADir/db/serial" }
    if (-not (Test-Path "$CADir/db/crlnumber"))       { '01' | Set-Content "$CADir/db/crlnumber" }
}

#endregion

#region ── Web Server Certificate ──────────────────────────────────────────────

function Get-WebCertDir {
    return '/ca/webserver'
}

function Initialize-WebServerCert {
    <#
    .SYNOPSIS
        Ensures a TLS certificate exists for the Pode web server.
        Generates a self-signed cert on first run. Stores in /ca/webserver/.
    #>
    $dir     = Get-WebCertDir
    $keyFile = "$dir/server.key"
    $crtFile = "$dir/server.crt"

    if ((Test-Path $keyFile) -and (Test-Path $crtFile)) {
        Write-Host '[Affix/CA] Web server certificate found.'
        return @{ Key = $keyFile; Cert = $crtFile }
    }

    Write-Host '[Affix/CA] No web server certificate — generating self-signed...'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Generate an unencrypted RSA key (no passphrase — Pode needs direct access)
    & openssl genrsa -out $keyFile 2048 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to generate web server private key' }

    # Self-signed cert valid for 1 year with SAN for localhost
    $cnfTmp = "$dir/_selfsigned.cnf"
    @"
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3
req_extensions     = v3

[dn]
CN = Affix/CA Web Server

[v3]
subjectAltName      = DNS:localhost,IP:127.0.0.1
keyUsage            = digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth
basicConstraints    = CA:FALSE
"@ | Set-Content $cnfTmp -Encoding UTF8

    & openssl req -new -x509 -key $keyFile -config $cnfTmp -days 365 -out $crtFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to generate self-signed web server certificate' }

    Remove-Item $cnfTmp -ErrorAction SilentlyContinue
    Write-Host '[Affix/CA] Self-signed web server certificate generated.'
    return @{ Key = $keyFile; Cert = $crtFile }
}

function New-WebServerCSR {
    <#
    .SYNOPSIS
        Generates a new private key + CSR for the web server.
        Returns the CSR PEM text.
    #>
    param(
        [string]$CommonName = 'Affix/CA Web Server',
        [string]$SANs = ''
    )
    $dir     = Get-WebCertDir
    $keyFile = "$dir/server.key"
    $csrFile = "$dir/server.csr"

    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Generate a fresh unencrypted key
    & openssl genrsa -out $keyFile 2048 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to generate web server private key' }

    # Build CSR config with SANs — always include CN and localhost
    $sanLine = "DNS:localhost,DNS:$CommonName"
    if ($SANs) {
        # Deduplicate in case CN is already in the list
        $extras = ($SANs -split ',') | ForEach-Object { $_.Trim() } | Where-Object {
            $_ -and $_ -ne "DNS:localhost" -and $_ -ne "DNS:$CommonName"
        }
        if ($extras) { $sanLine = "$sanLine,$($extras -join ',')" }
    }

    $cnfTmp = "$dir/_csr.cnf"
    @"
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = v3

[dn]
CN = $CommonName

[v3]
subjectAltName      = $sanLine
keyUsage            = digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth
basicConstraints    = CA:FALSE
"@ | Set-Content $cnfTmp -Encoding UTF8

    & openssl req -new -key $keyFile -config $cnfTmp -out $csrFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'CSR generation failed' }

    Remove-Item $cnfTmp -ErrorAction SilentlyContinue
    $csrPem = Get-Content $csrFile -Raw
    return $csrPem
}

function Install-WebServerCert {
    <#
    .SYNOPSIS
        Installs a signed certificate for the web server.
        Accepts PEM certificate text. The matching key must already exist.
    #>
    param([string]$CertPEM)

    $dir     = Get-WebCertDir
    $keyFile = "$dir/server.key"
    $crtFile = "$dir/server.crt"

    if (-not (Test-Path $keyFile)) {
        throw 'No server private key found. Generate a CSR first.'
    }

    # Write the cert
    $CertPEM | Set-Content $crtFile -Encoding UTF8

    # Verify the cert matches the key
    $certMod = & openssl x509 -noout -modulus -in $crtFile 2>&1
    $keyMod  = & openssl rsa  -noout -modulus -in $keyFile 2>&1
    if ($certMod -ne $keyMod) {
        throw 'Certificate does not match the private key. Did you generate a new CSR since this cert was signed?'
    }

    Write-Host '[Affix/CA] Web server certificate installed.'
    return @{ Key = $keyFile; Cert = $crtFile }
}

#endregion

#region ── Key Generation ──────────────────────────────────────────────────────

function New-CAPrivateKey {
    param(
        [string]$KeyPath,
        [string]$SecretFile,
        [ValidateSet('rsa','ecdsa')]
        [string]$Algorithm = 'rsa',
        [int]$KeySize       = 4096,
        [string]$Curve      = 'P-384'
    )

    if ($Algorithm -eq 'ecdsa') {
        $curveName = switch ($Curve) {
            'P-256' { 'prime256v1' }
            'P-384' { 'secp384r1'  }
            'P-521' { 'secp521r1'  }
            default { 'secp384r1'  }
        }
        & openssl genpkey -algorithm EC `
            -pkeyopt "ec_paramgen_curve:$curveName" `
            -aes-256-cbc -pass "file:$SecretFile" -out $KeyPath
    } else {
        & openssl genpkey -algorithm RSA `
            -pkeyopt "rsa_keygen_bits:$KeySize" `
            -aes-256-cbc -pass "file:$SecretFile" -out $KeyPath
    }
    if ($LASTEXITCODE -ne 0) { throw "Key generation failed (exit $LASTEXITCODE)" }
    & chmod 400 $KeyPath
}

function New-EEPrivateKey {
    param(
        [string]$KeyPath,
        [ValidateSet('rsa','ecdsa')]
        [string]$Algorithm = 'ecdsa',
        [int]$KeySize       = 2048,
        [string]$Curve      = 'P-256',
        [string]$Passphrase  = $null
    )

    if ($Algorithm -eq 'ecdsa') {
        $curveName = switch ($Curve) {
            'P-256' { 'prime256v1' }
            'P-384' { 'secp384r1'  }
            default { 'prime256v1' }
        }
        if ($Passphrase) {
            & openssl genpkey -algorithm EC -pkeyopt "ec_paramgen_curve:$curveName" `
                -aes-256-cbc -pass "pass:$Passphrase" -out $KeyPath
        } else {
            & openssl genpkey -algorithm EC -pkeyopt "ec_paramgen_curve:$curveName" -out $KeyPath
        }
    } else {
        if ($Passphrase) {
            & openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KeySize" `
                -aes-256-cbc -pass "pass:$Passphrase" -out $KeyPath
        } else {
            & openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KeySize" -out $KeyPath
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "EE key generation failed" }
}

#endregion

#region ── CSR & Certificate Operations ───────────────────────────────────────

function New-CACSR {
    param(
        [string]$KeyPath, [string]$CsrPath,
        [string]$ConfigPath, [string]$SecretFile
    )
    & openssl req -new -config $ConfigPath -key $KeyPath -passin "file:$SecretFile" -out $CsrPath
    if ($LASTEXITCODE -ne 0) { throw "CSR generation failed" }
}

function New-SelfSignedCACert {
    param(
        [string]$KeyPath, [string]$CertPath,
        [string]$ConfigPath, [string]$SecretFile,
        [int]$Days = 10957
    )
    $output = & openssl req -new -x509 `
        -config $ConfigPath -key $KeyPath -passin "file:$SecretFile" `
        -days $Days -sha384 -extensions ca_reqext -out $CertPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Self-signed cert generation failed: $output" }
}

function Invoke-SignCSR {
    param(
        [string]$CsrPath, [string]$CertPath, [string]$ConfigPath,
        [string]$ExtFile, [string]$ExtSection,
        [string]$SecretFile, [int]$Days = 365
    )
    $opensslArgs = @(
        'ca', '-batch', '-config', $ConfigPath,
        '-in', $CsrPath, '-out', $CertPath,
        '-days', $Days, '-passin', "file:$SecretFile", '-md', 'sha384'
    )
    if ($ExtFile)    { $opensslArgs += '-extfile';    $opensslArgs += $ExtFile }
    if ($ExtSection) { $opensslArgs += '-extensions'; $opensslArgs += $ExtSection }

    $output = & openssl @opensslArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "CSR signing failed: $output" }
}

function Revoke-Certificate {
    param(
        [string]$CertPath, [string]$ConfigPath, [string]$SecretFile,
        [ValidateSet('unspecified','keyCompromise','CACompromise','affiliationChanged',
                     'superseded','cessationOfOperation','certificateHold')]
        [string]$Reason = 'unspecified'
    )
    & openssl ca -revoke $CertPath -config $ConfigPath -passin "file:$SecretFile" -crl_reason $Reason
    if ($LASTEXITCODE -ne 0) { throw "Certificate revocation failed" }
}

function New-CRL {
    param(
        [string]$ConfigPath, [string]$SecretFile,
        [string]$CrlPemPath, [string]$CrlDerPath
    )
    & openssl ca -gencrl -config $ConfigPath -passin "file:$SecretFile" -out $CrlPemPath
    if ($LASTEXITCODE -ne 0) { throw "CRL generation failed" }
    & openssl crl -in $CrlPemPath -outform DER -out $CrlDerPath
}

#endregion

#region ── Certificate Parsing ─────────────────────────────────────────────────

function Get-CertInfo {
    param([string]$CertPath)

    $serial    = (& openssl x509 -in $CertPath -noout -serial 2>&1) -replace 'serial=',''
    $subject   = (& openssl x509 -in $CertPath -noout -subject 2>&1) -replace 'subject=',''
    $issuer    = (& openssl x509 -in $CertPath -noout -issuer  2>&1) -replace 'issuer=',''
    $notBefore = (& openssl x509 -in $CertPath -noout -startdate 2>&1) -replace 'notBefore=',''
    $notAfter  = (& openssl x509 -in $CertPath -noout -enddate  2>&1) -replace 'notAfter=',''
    $fp        = (& openssl x509 -in $CertPath -noout -fingerprint -sha256 2>&1) -replace 'SHA256 Fingerprint=',''

    $cleanDate = ($notAfter -replace '\s*GMT\s*$', '').Trim() -replace '\s+', ' '
    if ($cleanDate -match '(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})') {
        $months = @{ Jan=1; Feb=2; Mar=3; Apr=4; May=5; Jun=6; Jul=7; Aug=8; Sep=9; Oct=10; Nov=11; Dec=12 }
        $expiry = [datetime]::new([int]$Matches[6], $months[$Matches[1]], [int]$Matches[2],
                                  [int]$Matches[3], [int]$Matches[4], [int]$Matches[5])
    } else {
        throw "Cannot parse certificate expiry date: '$cleanDate'"
    }
    $daysLeft = [int](($expiry - (Get-Date)).TotalDays)

    return @{
        serial       = $serial.Trim()
        subject      = $subject.Trim()
        issuer       = $issuer.Trim()
        notBefore    = $notBefore.Trim()
        notAfter     = $notAfter.Trim()
        daysUntilExp = $daysLeft
        fingerprint  = $fp.Trim()
        pem          = (Get-Content $CertPath -Raw)
    }
}

function Get-DBStats {
    param([string]$CADir = '/ca')
    $dbPath = "$CADir/db/index.txt"
    if (-not (Test-Path $dbPath)) { return @{ total=0; valid=0; revoked=0; expired=0 } }

    $lines   = Get-Content $dbPath | Where-Object { $_ -match '\S' }
    $valid   = ($lines | Where-Object { $_ -match '^V' }).Count
    $revoked = ($lines | Where-Object { $_ -match '^R' }).Count
    $expired = ($lines | Where-Object { $_ -match '^E' }).Count

    return @{ total = $lines.Count; valid = $valid; revoked = $revoked; expired = $expired }
}

function Get-CertList {
    param([string]$CADir = '/ca')
    $dbPath = "$CADir/db/index.txt"
    $results = @()
    if (-not (Test-Path $dbPath)) { return $results }

    foreach ($line in (Get-Content $dbPath | Where-Object { $_ -match '\S' })) {
        $parts = $line -split '\t'
        if ($parts.Count -lt 6) { continue }

        $status    = $parts[0]
        $expiryRaw = $parts[1]
        $serial    = $parts[3]
        $subjectDN = $parts[5]

        $expiry   = [datetime]::ParseExact($expiryRaw.Substring(0,12), 'yyMMddHHmmss', $null)
        $daysLeft = [int](($expiry - (Get-Date)).TotalDays)

        $statusStr = switch ($status) {
            'V' { if ($daysLeft -lt 0) { 'expired' } elseif ($daysLeft -lt 30) { 'expiring' } else { 'valid' } }
            'R' { 'revoked' }
            'E' { 'expired' }
            default { 'unknown' }
        }

        $cn = ($subjectDN -split '/') | Where-Object { $_ -match '^CN=' } | Select-Object -First 1
        $cn = $cn -replace '^CN=', ''

        $results += @{
            serial   = $serial.Trim()
            subject  = $subjectDN.Trim()
            cn       = $cn.Trim()
            status   = $statusStr
            notAfter = $expiry.ToString('yyyy-MM-ddTHH:mm:ssZ')
            daysLeft = $daysLeft
            hasPem   = (Test-Path "$CADir/issued/$serial.pem")
        }
    }
    return $results | Sort-Object { $_.daysLeft }
}

#endregion

#region ── PKCS#12 / Chain Helpers ────────────────────────────────────────────

function New-PKCS12Bundle {
    param(
        [string]$CertPath, [string]$KeyPath, [string]$ChainPath,
        [string]$P12Path, [string]$FriendlyName, [string]$P12Password
    )
    $opensslArgs = @(
        'pkcs12', '-export', '-in', $CertPath, '-inkey', $KeyPath,
        '-certfile', $ChainPath, '-name', $FriendlyName,
        '-passout', "pass:$P12Password", '-out', $P12Path, '-legacy'
    )
    & openssl @opensslArgs
    if ($LASTEXITCODE -ne 0) { throw "PKCS#12 export failed" }
}

function Get-ChainPEM {
    param([string]$CADir = '/ca')
    $chainFile = "$CADir/chain/chain.pem"
    if (Test-Path $chainFile) { return Get-Content $chainFile -Raw }
    # Try ca-chain.pem fallback
    $altChain = "$CADir/chain/ca-chain.pem"
    if (Test-Path $altChain) { return Get-Content $altChain -Raw }
    return ''
}

function Build-FullChainPEM {
    <#
    .SYNOPSIS
        Builds the full trust chain from this CA up to root.
        For standalone: concatenates issuing + intermediate + root certs.
        For distributed: returns whatever chain.pem contains.
    #>
    param([object]$Config)

    if (-not $Config) { return '' }

    if ($Config.standalone -eq $true) {
        $chain = ''
        # Issuing CA cert
        $issuingCert = '/ca/issuing/certs/ca.crt'
        if (Test-Path $issuingCert) { $chain += (Get-Content $issuingCert -Raw) + "`n" }
        # Intermediate CA cert
        $intermCert = '/ca/intermediate/certs/ca.crt'
        if (Test-Path $intermCert) { $chain += (Get-Content $intermCert -Raw) + "`n" }
        # Root CA cert
        $rootCert = '/ca/root/certs/ca.crt'
        if (Test-Path $rootCert) { $chain += (Get-Content $rootCert -Raw) + "`n" }
        return $chain.TrimEnd()
    }

    # Distributed: this node's own cert + parent chain
    $chain = ''
    $selfCert = '/ca/certs/ca.crt'
    if (Test-Path $selfCert) { $chain += (Get-Content $selfCert -Raw) + "`n" }
    $parentChain = Get-ChainPEM
    if ($parentChain) { $chain += $parentChain + "`n" }
    return $chain.TrimEnd()
}

#endregion

#region ── OpenSSL Config Patching ─────────────────────────────────────────────

function New-PatchedConfig {
    <#
    .SYNOPSIS
        Creates a patched OpenSSL config from a template, setting subject DN fields
        and distribution point URLs. Section-aware to avoid corrupting policy sections.
    #>
    param(
        [string]$TemplatePath,
        [string]$OutputPath,
        [hashtable]$Subject,
        [string]$CdpUrl,
        [string]$AiaUrl,
        [string]$OcspUrl,
        [int]$CrlDays = 0,
        [string]$CaSectionName = ''
    )

    $rawLines = Get-Content $TemplatePath
    $configContent = ''
    $currentSection = ''

    foreach ($line in $rawLines) {
        if ($line -match '^\s*\[\s*(\S+)\s*\]') { $currentSection = $Matches[1] }

        # Patch [default] section — URLs
        if ($currentSection -eq 'default') {
            if ($CdpUrl)  { $line = $line -replace '^(base_url\s*=\s*).*',  ('${1}' + $CdpUrl) }
            if ($AiaUrl)  { $line = $line -replace '^(aia_url\s*=\s*).*',   ('${1}' + $AiaUrl) }
            if ($OcspUrl) { $line = $line -replace '^(ocsp_url\s*=\s*).*',  ('${1}' + $OcspUrl) }
        }

        # Patch CA section — CRL days
        if ($CaSectionName -and $currentSection -eq $CaSectionName -and $CrlDays -gt 0) {
            $line = $line -replace '^(default_crl_days\s*=\s*).*', ('${1}' + $CrlDays)
        }

        # Patch [ca_dn] section ONLY — identity fields
        if ($currentSection -eq 'ca_dn') {
            if ($Subject.c)  { $line = $line -replace '^(countryName\s*=\s*).*',      ('${1}' + '"' + $Subject.c + '"') }
            if ($Subject.o)  { $line = $line -replace '^(organizationName\s*=\s*).*', ('${1}' + '"' + $Subject.o + '"') }
            if ($Subject.cn) { $line = $line -replace '^(commonName\s*=\s*).*',       ('${1}' + '"' + $Subject.cn + '"') }
        }

        $configContent += $line + "`n"
    }

    # Insert optional state/locality into [ca_dn]
    if ($Subject.st -or $Subject.l) {
        $extra = ''
        if ($Subject.st) { $extra += "`nstateOrProvinceName     = `"$($Subject.st)`"" }
        if ($Subject.l)  { $extra += "`nlocalityName            = `"$($Subject.l)`"" }
        $configContent = $configContent -replace '(\[\s*ca_dn\s*\][^\[]*?countryName\s*=\s*"[^"]*")', ('${1}' + $extra)
    }

    # Update dir path if standalone
    if ($OutputPath -match '/ca/(root|intermediate|issuing)/') {
        $tier = $Matches[1]
        $configContent = $configContent -replace '(dir\s*=\s*).*', ('${1}/ca/' + $tier)
    }

    $configContent | Set-Content $OutputPath
}

function Update-CAConfig {
    <#
    .SYNOPSIS
        Patches the [ca_dn] section and regenerates the CSR.
        Used by /api/ceremony/configure for chain-init propagation.
    #>
    param(
        [string]$ConfigPath = '/app/config/openssl/issuing-ca.cnf',
        [string]$Country, [string]$State, [string]$Locality,
        [string]$Organization, [string]$CommonName,
        [string]$KeyPath = '/ca/private/ca.key',
        [string]$CsrPath = '/ca/csr/ca.csr',
        [string]$SecretFile
    )

    $lines = Get-Content $ConfigPath
    $result = @()
    $currentSection = ''
    foreach ($line in $lines) {
        if ($line -match '^\s*\[\s*(\S+)\s*\]') { $currentSection = $Matches[1] }
        if ($currentSection -eq 'ca_dn') {
            if ($Country      -and $line -match '^countryName\s*=')      { $line = "countryName             = `"$Country`"" }
            if ($Organization -and $line -match '^organizationName\s*=') { $line = "organizationName        = `"$Organization`"" }
            if ($CommonName   -and $line -match '^commonName\s*=')       { $line = "commonName              = `"$CommonName`"" }
        }
        $result += $line
    }
    $result | Set-Content $ConfigPath

    if ((Test-Path $KeyPath) -and $SecretFile) {
        New-CACSR -KeyPath $KeyPath -CsrPath $CsrPath -ConfigPath $ConfigPath -SecretFile $SecretFile
    }
}

#endregion

#region ── Certificate Template System ─────────────────────────────────────────

function Get-CertTemplates {
    <#
    .SYNOPSIS
        Loads certificate template definitions from JSON files.
        Volume overrides (/ca/templates/) take precedence over built-in (/app/templates/).
    #>
    param([string[]]$EnabledTemplates = @())

    $templates = @{}

    # Load built-in templates
    $builtIn = '/app/templates'
    if (Test-Path $builtIn) {
        foreach ($f in (Get-ChildItem $builtIn -Filter '*.json')) {
            $t = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $templates[$t.id] = $t
        }
    }

    # Load volume overrides (take precedence)
    $custom = '/ca/templates'
    if (Test-Path $custom) {
        foreach ($f in (Get-ChildItem $custom -Filter '*.json')) {
            $t = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $templates[$t.id] = $t
        }
    }

    # Filter to enabled templates if specified
    if ($EnabledTemplates.Count -gt 0) {
        $filtered = @{}
        foreach ($id in $EnabledTemplates) {
            if ($templates.ContainsKey($id)) { $filtered[$id] = $templates[$id] }
        }
        return $filtered.Values | Sort-Object { $_.name }
    }

    return $templates.Values | Sort-Object { $_.name }
}

function New-DynamicExtFile {
    <#
    .SYNOPSIS
        Generates a temporary OpenSSL extension file from a template definition and SAN entries.
        If the template has an opensslExtFile, loads it and appends SANs.
        If dynamicExt is true, builds the extension file from template fields.
    #>
    param(
        [object]$Template,
        [string[]]$SANEntries = @(),
        [string]$OutputPath
    )

    if ($Template.opensslExtFile -and -not $Template.dynamicExt) {
        # Load the static profile .cnf and append SANs
        $profilePath = "/app/config/openssl/profiles/$($Template.opensslExtFile)"
        if (-not (Test-Path $profilePath)) { throw "Profile config not found: $profilePath" }
        $extContent = Get-Content $profilePath -Raw

        # Strip CDP/AIA/OCSP sections if environment variables aren't set
        $cdp  = $env:CDP_URL  ?? ''
        $ocsp = $env:OCSP_URL ?? ''
        $aia  = $env:AIA_URL  ?? ''
        if (-not $cdp) {
            $extContent = $extContent -replace '(?m)^crlDistributionPoints\s*=.*\r?\n', ''
            $extContent = $extContent -replace '(?ms)\[\s*crl_info\s*\].*?(?=\[|\z)', ''
        }
        if (-not $ocsp -and -not $aia) {
            $extContent = $extContent -replace '(?m)^authorityInfoAccess\s*=.*\r?\n', ''
            $extContent = $extContent -replace '(?ms)\[\s*ocsp_issuer_info\s*\].*?(?=\[|\z)', ''
        } else {
            # Replace env var references with actual values
            if ($ocsp) { $extContent = $extContent -replace '\$\{ENV::OCSP_URL\}', $ocsp }
            else { $extContent = $extContent -replace '(?m)^OCSP;URI\.0\s*=.*\r?\n', '' }
            if ($aia) { $extContent = $extContent -replace '\$\{ENV::AIA_URL\}', $aia }
            else { $extContent = $extContent -replace '(?m)^caIssuers;URI\.0\s*=.*\r?\n', '' }
        }
        if ($cdp) { $extContent = $extContent -replace '\$\{ENV::CDP_URL\}', $cdp }

        if ($SANEntries.Count -gt 0) {
            $sanLine = "subjectAltName = " + ($SANEntries -join ', ')
            if ($extContent -match 'subjectAltName\s*=') {
                $extContent = $extContent -replace 'subjectAltName\s*=.*', $sanLine
            } else {
                $extContent += "`n$sanLine`n"
            }
        }
        $extContent | Set-Content $OutputPath
        # Return the section name (first section in the file)
        $section = if ($extContent -match '(?m)^\[\s*(\S+)\s*\]') { $Matches[1] } else { '' }
        return $section
    }

    # Build dynamic extension file from template JSON
    $lines = @()
    $lines += '[ cert_ext ]'
    $lines += 'subjectKeyIdentifier    = hash'
    $lines += 'authorityKeyIdentifier  = keyid:always'
    $lines += 'basicConstraints        = critical,CA:false'

    if ($Template.keyUsage) {
        $ku = ($Template.keyUsage -join ',')
        $critical = if ($Template.critical) { 'critical,' } else { '' }
        $lines += "keyUsage                = ${critical}${ku}"
    }

    if ($Template.ekus) {
        $ekuStr = ($Template.ekus -join ',')
        $lines += "extendedKeyUsage        = $ekuStr"
    }

    if ($SANEntries.Count -gt 0) {
        $lines += "subjectAltName          = " + ($SANEntries -join ', ')
    }

    # Add CDP and AIA from environment
    $cdp  = $env:CDP_URL  ?? ''
    $ocsp = $env:OCSP_URL ?? ''
    $aia  = $env:AIA_URL  ?? ''
    if ($cdp -or $ocsp -or $aia) {
        $lines += ''
        if ($cdp) {
            $lines += '[ crl_info ]'
            $lines += "URI.0                   = $cdp"
            $lines += ''
        }
        if ($ocsp -or $aia) {
            $lines += '[ ocsp_issuer_info ]'
            if ($ocsp) { $lines += "OCSP;URI.0              = $ocsp" }
            if ($aia)  { $lines += "caIssuers;URI.0         = $aia" }
        }
        # Reference from main section
        if ($cdp)             { $lines[0] += '' }  # placeholder
        $insertIdx = 5  # after basicConstraints
        if ($cdp)  { $lines = $lines[0..$insertIdx] + @("crlDistributionPoints   = @crl_info") + $lines[($insertIdx+1)..($lines.Count-1)] }
        if ($ocsp) { $lines = $lines[0..($insertIdx+1)] + @("authorityInfoAccess     = @ocsp_issuer_info") + $lines[($insertIdx+2)..($lines.Count-1)] }
    }

    ($lines -join "`n") | Set-Content $OutputPath
    return 'cert_ext'
}

#endregion

#region ── Standalone Ceremony ─────────────────────────────────────────────────

function Initialize-StandaloneCA {
    <#
    .SYNOPSIS
        Full standalone ceremony: Root → Intermediate → Issuing, all in one pass.
        Called by the setup wizard in standalone mode.
    #>
    param(
        [hashtable]$Subject,
        [string]$KeyAlgo = 'rsa',
        [string]$KeyParam = '4096',
        [int]$RootDays = 10957,
        [int]$IntermediateDays = 5475,
        [int]$IssuingDays = 3652,
        [int]$CrlDays = 3650,
        [string]$CdpUrl = '',
        [string]$AiaUrl = '',
        [string]$OcspUrl = '',
        [string]$SecretFile = '/run/secrets/ca_pass',
        [string[]]$Templates = @('tls-server', 'tls-client')
    )

    $steps = @()
    $keySize = if ($KeyAlgo -eq 'rsa') { [int]$KeyParam } else { 0 }
    $curve   = if ($KeyAlgo -eq 'ecdsa') { $KeyParam } else { 'P-384' }

    # ══════════════════════════════════════════════════════════════════════════
    # Step 1: Root CA
    # ══════════════════════════════════════════════════════════════════════════
    Write-Host '[Standalone] Step 1/3: Initializing Root CA...'
    $rootDir = '/ca/root'
    Initialize-CADirectories -CADir $rootDir

    $rootSubject = @{
        c  = $Subject.c ?? 'US'
        st = $Subject.st
        l  = $Subject.l
        o  = $Subject.o ?? 'Example'
        cn = $Subject.cn ?? "$($Subject.o) Root CA"
    }

    # Patch root config
    $rootCfg = "$rootDir/ca.cnf"
    New-PatchedConfig -TemplatePath '/app/config/openssl/root-ca.cnf' `
        -OutputPath $rootCfg -Subject $rootSubject `
        -CdpUrl $CdpUrl -AiaUrl $AiaUrl -OcspUrl $OcspUrl `
        -CrlDays $CrlDays -CaSectionName 'root_ca'

    # Fix dir path for standalone
    $cfgContent = Get-Content $rootCfg -Raw
    $cfgContent = $cfgContent -replace '(dir\s*=\s*).*', '${1}/ca/root'
    $cfgContent | Set-Content $rootCfg

    # Generate root key
    Write-Host '[Standalone]   Generating Root CA key...'
    New-CAPrivateKey -KeyPath "$rootDir/private/ca.key" -SecretFile $SecretFile `
        -Algorithm $KeyAlgo -KeySize $keySize -Curve $curve

    # Self-sign root
    Write-Host '[Standalone]   Self-signing Root CA certificate...'
    New-SelfSignedCACert -KeyPath "$rootDir/private/ca.key" -CertPath "$rootDir/certs/ca.crt" `
        -ConfigPath $rootCfg -SecretFile $SecretFile -Days $RootDays

    # Root CRL
    New-CRL -ConfigPath $rootCfg -SecretFile $SecretFile `
        -CrlPemPath "$rootDir/crl/ca.crl.pem" -CrlDerPath "$rootDir/crl/ca.crl"

    $rootInfo = Get-CertInfo -CertPath "$rootDir/certs/ca.crt"
    $steps += @{ name = 'Root CA'; status = 'created'; serial = $rootInfo.serial }
    Write-Host "[Standalone]   Root CA created (serial: $($rootInfo.serial))"

    # ══════════════════════════════════════════════════════════════════════════
    # Step 2: Intermediate CA
    # ══════════════════════════════════════════════════════════════════════════
    Write-Host '[Standalone] Step 2/3: Initializing Intermediate CA...'
    $intermDir = '/ca/intermediate'
    Initialize-CADirectories -CADir $intermDir

    $intermSubject = @{
        c  = $rootSubject.c
        o  = $rootSubject.o
        cn = "$($rootSubject.o) Policy CA"
    }

    $intermCfg = "$intermDir/ca.cnf"
    New-PatchedConfig -TemplatePath '/app/config/openssl/intermediate-ca.cnf' `
        -OutputPath $intermCfg -Subject $intermSubject `
        -CdpUrl $CdpUrl -AiaUrl $AiaUrl -OcspUrl $OcspUrl `
        -CaSectionName 'intermediate_ca'

    $cfgContent = Get-Content $intermCfg -Raw
    $cfgContent = $cfgContent -replace '(dir\s*=\s*).*', '${1}/ca/intermediate'
    $cfgContent | Set-Content $intermCfg

    # Generate intermediate key + CSR
    Write-Host '[Standalone]   Generating Intermediate CA key...'
    New-CAPrivateKey -KeyPath "$intermDir/private/ca.key" -SecretFile $SecretFile `
        -Algorithm $KeyAlgo -KeySize $keySize -Curve $curve

    New-CACSR -KeyPath "$intermDir/private/ca.key" -CsrPath "$intermDir/csr/ca.csr" `
        -ConfigPath $intermCfg -SecretFile $SecretFile

    # Sign with root
    Write-Host '[Standalone]   Signing Intermediate CA with Root...'
    Invoke-SignCSR -CsrPath "$intermDir/csr/ca.csr" -CertPath "$intermDir/certs/ca.crt" `
        -ConfigPath $rootCfg -ExtSection 'intermediate_ca_ext' `
        -SecretFile $SecretFile -Days $IntermediateDays

    # Build intermediate chain
    $rootPEM = Get-Content "$rootDir/certs/ca.crt" -Raw
    $rootPEM | Set-Content "$intermDir/chain/chain.pem"

    # Intermediate CRL
    New-CRL -ConfigPath $intermCfg -SecretFile $SecretFile `
        -CrlPemPath "$intermDir/crl/ca.crl.pem" -CrlDerPath "$intermDir/crl/ca.crl"

    $intermInfo = Get-CertInfo -CertPath "$intermDir/certs/ca.crt"
    $steps += @{ name = 'Intermediate CA'; status = 'signed'; serial = $intermInfo.serial }
    Write-Host "[Standalone]   Intermediate CA signed (serial: $($intermInfo.serial))"

    # ══════════════════════════════════════════════════════════════════════════
    # Step 3: Issuing CA
    # ══════════════════════════════════════════════════════════════════════════
    Write-Host '[Standalone] Step 3/3: Initializing Issuing CA...'
    $issuingDir = '/ca/issuing'
    Initialize-CADirectories -CADir $issuingDir

    $issuingSubject = @{
        c  = $rootSubject.c
        o  = $rootSubject.o
        cn = "$($rootSubject.o) Issuing CA"
    }

    $issuingCfg = "$issuingDir/ca.cnf"
    New-PatchedConfig -TemplatePath '/app/config/openssl/issuing-ca.cnf' `
        -OutputPath $issuingCfg -Subject $issuingSubject `
        -CdpUrl $CdpUrl -AiaUrl $AiaUrl -OcspUrl $OcspUrl `
        -CaSectionName 'issuing_ca'

    $cfgContent = Get-Content $issuingCfg -Raw
    $cfgContent = $cfgContent -replace '(dir\s*=\s*).*', '${1}/ca/issuing'
    $cfgContent | Set-Content $issuingCfg

    # Generate issuing key + CSR
    Write-Host '[Standalone]   Generating Issuing CA key...'
    New-CAPrivateKey -KeyPath "$issuingDir/private/ca.key" -SecretFile $SecretFile `
        -Algorithm 'ecdsa' -Curve 'P-384'

    New-CACSR -KeyPath "$issuingDir/private/ca.key" -CsrPath "$issuingDir/csr/ca.csr" `
        -ConfigPath $issuingCfg -SecretFile $SecretFile

    # Sign with intermediate
    Write-Host '[Standalone]   Signing Issuing CA with Intermediate...'
    Invoke-SignCSR -CsrPath "$issuingDir/csr/ca.csr" -CertPath "$issuingDir/certs/ca.crt" `
        -ConfigPath $intermCfg -ExtSection 'issuing_ca_ext' `
        -SecretFile $SecretFile -Days $IssuingDays

    # Build issuing chain (intermediate + root)
    $intermPEM = Get-Content "$intermDir/certs/ca.crt" -Raw
    "$intermPEM`n$rootPEM" | Set-Content "$issuingDir/chain/chain.pem"

    # Issuing CRL
    New-CRL -ConfigPath $issuingCfg -SecretFile $SecretFile `
        -CrlPemPath "$issuingDir/crl/ca.crl.pem" -CrlDerPath "$issuingDir/crl/ca.crl"

    $issuingInfo = Get-CertInfo -CertPath "$issuingDir/certs/ca.crt"
    $steps += @{ name = 'Issuing CA'; status = 'signed'; serial = $issuingInfo.serial }
    Write-Host "[Standalone]   Issuing CA signed (serial: $($issuingInfo.serial))"

    # ══════════════════════════════════════════════════════════════════════════
    # Save config.json
    # ══════════════════════════════════════════════════════════════════════════
    $config = @{
        instanceId  = [System.Guid]::NewGuid().ToString()
        roles       = @('root', 'intermediate', 'issuing')
        standalone  = $true
        caName      = $rootSubject.cn
        subject     = $rootSubject
        keyAlgo     = $KeyAlgo
        keyParam    = $KeyParam
        days        = $RootDays
        crlDays     = $CrlDays
        cdpUrl      = $CdpUrl
        aiaUrl      = $AiaUrl
        ocspUrl     = $OcspUrl
        templates   = $Templates
        createdAt   = (Get-Date -Format 'o')
    }
    Save-InstanceConfig -Config $config

    Write-Host '[Standalone] Full PKI chain initialized.'
    return @{ success = $true; steps = $steps; config = $config }
}

#endregion

#region ── Distributed Helpers ─────────────────────────────────────────────────

function Wait-ForService {
    param([string]$ServiceUrl, [int]$MaxRetries = 30, [int]$DelaySec = 2)
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            Invoke-RestMethod -Uri "$ServiceUrl/api/health" -TimeoutSec 3 | Out-Null
            return
        } catch {
            Start-Sleep -Seconds $DelaySec
        }
    }
    throw "Service at $ServiceUrl not reachable after $($MaxRetries * $DelaySec) seconds"
}

#endregion

#region ── Authentication ─────────────────────────────────────────────────────

function New-RandomBytes {
    param([int]$Count = 32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Count
    $rng.GetBytes($bytes)
    return $bytes
}

function New-Salt { return [Convert]::ToBase64String((New-RandomBytes -Count 32)) }
function New-AuthToken { return [Convert]::ToBase64String((New-RandomBytes -Count 48)) }

function Get-PasswordHash {
    param([string]$Password, [string]$Salt)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Password + $Salt)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return [Convert]::ToBase64String($sha.ComputeHash($bytes))
}

function Get-AuthStorePath {
    # Persist in /ca so it survives container rebuilds (volume-mounted)
    return '/ca/auth.json'
}

function Get-AuthStore {
    $path = Get-AuthStorePath
    if (-not (Test-Path $path)) { return $null }
    try {
        $store = Get-Content -Path $path -Raw | ConvertFrom-Json
        if (-not ($store.PSObject.Properties.Name -contains 'users'))     { $store | Add-Member -NotePropertyName 'users'     -NotePropertyValue @() }
        if (-not ($store.PSObject.Properties.Name -contains 'sessions'))  { $store | Add-Member -NotePropertyName 'sessions'  -NotePropertyValue @() }
        if (-not ($store.PSObject.Properties.Name -contains 'apiTokens')) { $store | Add-Member -NotePropertyName 'apiTokens' -NotePropertyValue @() }
        return $store
    } catch { return $null }
}

function Save-AuthStore {
    param($Store)
    $Store | ConvertTo-Json -Depth 10 | Set-Content -Path (Get-AuthStorePath) -Encoding UTF8
}

function Get-AuthUser {
    $authHeader = Get-PodeHeader -Name 'Authorization'
    if (-not $authHeader -or $authHeader -notmatch '^Bearer\s+(.+)$') { return $null }
    $tkn = $Matches[1]
    $store = Get-AuthStore
    if (-not $store) { return $null }
    $now = Get-Date
    foreach ($s in @($store.sessions)) {
        if ($s -and $s.token -eq $tkn -and $s.expiresAt) {
            try { if ([datetime]::Parse($s.expiresAt) -gt $now) {
                return ($store.users | Where-Object { $_.username -eq $s.username } | Select-Object -First 1)
            }} catch {}
        }
    }
    foreach ($t in @($store.apiTokens)) {
        if ($t -and $t.token -eq $tkn) {
            return ($store.users | Where-Object { $_.username -eq $t.createdBy } | Select-Object -First 1)
        }
    }
    return $null
}

function Initialize-AuthStore {
    $path = Get-AuthStorePath
    if (-not (Test-Path $path)) {
        $salt = New-Salt
        $hash = Get-PasswordHash -Password 'admin' -Salt $salt
        $store = [PSCustomObject]@{
            users     = @([PSCustomObject]@{ username = 'admin'; passwordHash = $hash; salt = $salt; role = 'admin'; createdAt = (Get-Date).ToString('o') })
            sessions  = @()
            apiTokens = @()
        }
        Save-AuthStore -Store $store
        Write-Host "Default admin user 'admin' created (password: admin)" -ForegroundColor Yellow
    }
}

function Register-PodeAuth {
    <#
    .SYNOPSIS
        Registers auth middleware, login page, and all auth API routes.
        Call inside Start-PodeServer { } after Add-PodeEndpoint.
    #>

    # ── Auth Middleware ──────────────────────────────────────────────────
    Add-PodeMiddleware -Name 'AuthCheck' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $path = $WebEvent.Path
        if (-not $path) { $path = $WebEvent.Request.Url.AbsolutePath }
        if (-not $path) { $path = '/' }

        # Public paths:
        #  - UI shell (HTML/CSS/JS are not sensitive; auth.js guards client-side)
        #  - Login route, auth login API, health, setup routes
        #  - Published PKI endpoints (AIA/CDP): chain downloads, CRL downloads
        #    These must be unauthenticated so any client can fetch CA certs & CRLs.
        # Only /api/* endpoints (except the above) require a Bearer token.
        if ($path -eq '/' -or
            $path -eq '/login' -or
            $path -like '/ui/*' -or
            $path -like '/api/auth/login*' -or
            $path -eq '/api/health' -or
            $path -like '/api/setup/*' -or
            $path -like '/api/chain*' -or
            $path -like '/api/crl/*') {
            return $true
        }

        # Allow ONLY internal container requests (loopback) without auth.
        # This covers inter-service calls (chain-init, health probes) but NOT browser users.
        $socketIp = ''
        try { $socketIp = "$($WebEvent.Request.RemoteEndPoint.Address)" } catch {}
        if ($socketIp -eq '127.0.0.1' -or $socketIp -eq '::1') {
            return $true
        }

        # Check Bearer token
        $authHeader = Get-PodeHeader -Name 'Authorization'
        if ($authHeader -and $authHeader -match '^Bearer\s+(.+)$') {
            $tkn = $Matches[1]
            $store = Get-AuthStore
            if ($store) {
                $now = Get-Date
                foreach ($s in @($store.sessions)) {
                    if ($s -and $s.token -eq $tkn) {
                        try { if ([datetime]::Parse($s.expiresAt) -gt $now) { return $true } } catch {}
                    }
                }
                foreach ($t in @($store.apiTokens)) {
                    if ($t -and $t.token -eq $tkn) { return $true }
                }
            }
        }

        # Reject — API gets 401 JSON, everything else gets redirect
        if ($path -like '/api/*') {
            Write-PodeJsonResponse -Value @{ error = 'Authentication required' } -StatusCode 401
        } else {
            Move-PodeResponseUrl -Url '/login'
        }
        return $false
    }

    # ── Login page ───────────────────────────────────────────────────────
    Add-PodeRoute -Method Get -Path '/login' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        Write-PodeHtmlResponse -Value (Get-Content -Path '/app/ui/login.html' -Raw)
    }

    # ── Auth API: Login ──────────────────────────────────────────────────
    Add-PodeRoute -Method Post -Path '/api/auth/login' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $body = $WebEvent.Data
        if (-not $body.username -or -not $body.password) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Username and password are required' } -StatusCode 400
            return
        }
        $store = Get-AuthStore
        if (-not $store) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Auth system not initialized' } -StatusCode 500
            return
        }
        $user = $store.users | Where-Object { $_.username -eq $body.username } | Select-Object -First 1
        if (-not $user) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Invalid username or password' } -StatusCode 401
            return
        }
        $hash = Get-PasswordHash -Password $body.password -Salt $user.salt
        if ($hash -ne $user.passwordHash) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Invalid username or password' } -StatusCode 401
            return
        }
        $token = New-AuthToken
        $now = Get-Date
        $expires = $now.AddHours(8)
        $store.sessions = @($store.sessions | Where-Object { $_ -and $_.expiresAt -and ([datetime]::Parse($_.expiresAt) -gt $now) })
        $store.sessions += [PSCustomObject]@{ token = $token; username = $user.username; createdAt = $now.ToString('o'); expiresAt = $expires.ToString('o') }
        Save-AuthStore -Store $store
        Write-PodeJsonResponse -Value @{ success = $true; token = $token; username = $user.username; role = $user.role; expiresAt = $expires.ToString('o') }
    }

    # ── Auth API: Logout ─────────────────────────────────────────────────
    Add-PodeRoute -Method Post -Path '/api/auth/logout' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $authHeader = Get-PodeHeader -Name 'Authorization'
        if ($authHeader -and $authHeader -match '^Bearer\s+(.+)$') {
            $tkn = $Matches[1]
            $store = Get-AuthStore
            if ($store) {
                $store.sessions = @($store.sessions | Where-Object { $_.token -ne $tkn })
                Save-AuthStore -Store $store
            }
        }
        Write-PodeJsonResponse -Value @{ success = $true; message = 'Logged out' }
    }

    # ── Auth API: Session check ──────────────────────────────────────────
    Add-PodeRoute -Method Get -Path '/api/auth/session' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $user = Get-AuthUser
        if ($user) {
            Write-PodeJsonResponse -Value @{ success = $true; username = $user.username; role = $user.role }
        } else {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Invalid or expired session' } -StatusCode 401
        }
    }

    # ── Auth API: List users (admin only) ────────────────────────────────
    Add-PodeRoute -Method Get -Path '/api/auth/users' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $user = Get-AuthUser
        if (-not $user -or $user.role -ne 'admin') {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Admin access required' } -StatusCode 403
            return
        }
        $store = Get-AuthStore
        $list = @($store.users | ForEach-Object { [PSCustomObject]@{ username = $_.username; role = $_.role; createdAt = $_.createdAt } })
        Write-PodeJsonResponse -Value @{ success = $true; users = $list }
    }

    # ── Auth API: Create user (admin only) ───────────────────────────────
    Add-PodeRoute -Method Post -Path '/api/auth/users' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $caller = Get-AuthUser
        if (-not $caller -or $caller.role -ne 'admin') {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Admin access required' } -StatusCode 403
            return
        }
        $body = $WebEvent.Data
        if (-not $body.username -or -not $body.password) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Username and password are required' } -StatusCode 400
            return
        }
        $store = Get-AuthStore
        $existing = $store.users | Where-Object { $_.username -eq $body.username }
        if ($existing) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'User already exists' } -StatusCode 409
            return
        }
        $salt = New-Salt
        $hash = Get-PasswordHash -Password $body.password -Salt $salt
        $role = if ($body.role) { $body.role } else { 'user' }
        $store.users += [PSCustomObject]@{ username = $body.username; passwordHash = $hash; salt = $salt; role = $role; createdAt = (Get-Date).ToString('o') }
        Save-AuthStore -Store $store
        Write-PodeJsonResponse -Value @{ success = $true; message = "User '$($body.username)' created" }
    }

    # ── Auth API: Update user (admin only) ───────────────────────────────
    Add-PodeRoute -Method Put -Path '/api/auth/users/:username' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $caller = Get-AuthUser
        if (-not $caller -or $caller.role -ne 'admin') {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Admin access required' } -StatusCode 403
            return
        }
        $targetName = $WebEvent.Parameters['username']
        $body = $WebEvent.Data
        $store = Get-AuthStore
        $target = $store.users | Where-Object { $_.username -eq $targetName } | Select-Object -First 1
        if (-not $target) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'User not found' } -StatusCode 404
            return
        }
        if ($body.password) {
            $salt = New-Salt
            $target.salt = $salt
            $target.passwordHash = Get-PasswordHash -Password $body.password -Salt $salt
        }
        if ($body.role) { $target.role = $body.role }
        Save-AuthStore -Store $store
        Write-PodeJsonResponse -Value @{ success = $true; message = "User '$targetName' updated" }
    }

    # ── Auth API: Delete user (admin only) ───────────────────────────────
    Add-PodeRoute -Method Delete -Path '/api/auth/users/:username' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $caller = Get-AuthUser
        if (-not $caller -or $caller.role -ne 'admin') {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Admin access required' } -StatusCode 403
            return
        }
        $targetName = $WebEvent.Parameters['username']
        if ($targetName -eq $caller.username) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Cannot delete your own account' } -StatusCode 400
            return
        }
        $store = Get-AuthStore
        $store.users = @($store.users | Where-Object { $_.username -ne $targetName })
        $store.sessions = @($store.sessions | Where-Object { $_.username -ne $targetName })
        $store.apiTokens = @($store.apiTokens | Where-Object { $_.createdBy -ne $targetName })
        Save-AuthStore -Store $store
        Write-PodeJsonResponse -Value @{ success = $true; message = "User '$targetName' deleted" }
    }

    # ── Auth API: Change own password ────────────────────────────────────
    Add-PodeRoute -Method Post -Path '/api/auth/change-password' -ScriptBlock {
        . /app/shared/scripts/Common-Functions.ps1
        $user = Get-AuthUser
        if (-not $user) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Authentication required' } -StatusCode 401
            return
        }
        $body = $WebEvent.Data
        if (-not $body.currentPassword -or -not $body.newPassword) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Current and new password are required' } -StatusCode 400
            return
        }
        $hash = Get-PasswordHash -Password $body.currentPassword -Salt $user.salt
        if ($hash -ne $user.passwordHash) {
            Write-PodeJsonResponse -Value @{ success = $false; message = 'Current password is incorrect' } -StatusCode 401
            return
        }
        $store = Get-AuthStore
        $target = $store.users | Where-Object { $_.username -eq $user.username } | Select-Object -First 1
        $salt = New-Salt
        $target.salt = $salt
        $target.passwordHash = Get-PasswordHash -Password $body.newPassword -Salt $salt
        Save-AuthStore -Store $store
        Write-PodeJsonResponse -Value @{ success = $true; message = 'Password changed successfully' }
    }
}

#endregion

#region ── Response Helpers ───────────────────────────────────────────────────

function Write-ErrorResponse {
    param([string]$Message, [int]$Code = 500)
    Set-PodeResponseStatus -Code $Code -Description $Message
    Write-PodeJsonResponse -Value @{ error = $Message; timestamp = (Get-Date -Format 'o') }
}

function Write-SuccessResponse {
    param([hashtable]$Data)
    $Data['timestamp'] = (Get-Date -Format 'o')
    Write-PodeJsonResponse -Value $Data
}

#endregion
