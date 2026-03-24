# =============================================================================
#  Common  ·  Logs API endpoints
#  GET  /api/logs       — Retrieve filtered log entries
#  POST /api/logs/clear — Clear log file
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/logs' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    $categories = $WebEvent.Query['categories']
    $levels     = $WebEvent.Query['levels']
    $since      = $WebEvent.Query['since']
    $limit      = [int]($WebEvent.Query['limit'] ?? 500)

    $catArray = if ($categories) { $categories -split ',' } else { @() }
    $lvlArray = if ($levels) { $levels -split ',' } else { @() }
    $sinceDate = $null
    if ($since) {
        try { $sinceDate = [datetime]::Parse($since) } catch {}
    }

    $params = @{ Limit = $limit }
    if ($catArray.Count -gt 0)  { $params.Categories = $catArray }
    if ($lvlArray.Count -gt 0)  { $params.Levels = $lvlArray }
    if ($sinceDate)             { $params.Since = $sinceDate }

    $entries = Get-LogEntries @params
    Write-PodeJsonResponse -Value @{
        entries = @($entries)
        count   = ($entries).Count
        limit   = $limit
    }
}

Add-PodeRoute -Method 'Post' -Path '/api/logs/clear' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1

    try {
        $logFile = '/ca/logs/server.log'
        $rotated = "$logFile.1"
        if (Test-Path $logFile)  { Remove-Item $logFile -Force }
        if (Test-Path $rotated)  { Remove-Item $rotated -Force }

        Write-Log -Message 'Log file cleared by administrator' -Category 'admin' -Level 'info'
        Write-PodeJsonResponse -Value @{ success = $true; message = 'Logs cleared.' }
    } catch {
        Write-PodeJsonResponse -Value @{ success = $false; error = $_.Exception.Message }
    }
}
