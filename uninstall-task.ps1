param (
    [string]$TaskName = "GH Runner Watcher"
)

$ErrorActionPreference = "Stop"

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $Task) {
    Write-Warning "Scheduled task '$TaskName' not found. Nothing to uninstall."
    return
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "🗑️ Removed scheduled task '$TaskName'."
