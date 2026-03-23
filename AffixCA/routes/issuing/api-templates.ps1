# =============================================================================
#  Issuing CA  ·  GET /api/templates — List available certificate templates
# =============================================================================

. /app/shared/scripts/Common-Functions.ps1

Add-PodeRoute -Method 'Get' -Path '/api/templates' -ScriptBlock {
    . /app/shared/scripts/Common-Functions.ps1
    try {
        $cfg = Get-InstanceConfig
        $enabled = @($cfg.templates ?? @())
        $templates = Get-CertTemplates -EnabledTemplates $enabled
        Write-PodeJsonResponse -Value @{
            templates = @($templates)
            count     = $templates.Count
        }
    } catch {
        Write-ErrorResponse -Message $_.Exception.Message
    }
}
