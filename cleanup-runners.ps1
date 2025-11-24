. "$PSScriptRoot/runner-api.ps1"

param (
    [Parameter(Mandatory = $true)]
    [string]$RepoFullName = $env:GITHUB_REPOSITORY,
    [Parameter(Mandatory = $true)]
    [string]$PatToken = $env:PAT_TOKEN,
    [string[]]$RunnerNames = @()
)

$ErrorActionPreference = "Stop"

if (-not $RunnerNames -or $RunnerNames.Count -eq 0) {
    if ($env:RUNNER_NAMES) {
        $RunnerNames = $env:RUNNER_NAMES.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
}

if (-not $RunnerNames -or $RunnerNames.Count -eq 0) {
    throw "RunnerNames are required (pass -RunnerNames or set RUNNER_NAMES env)."
}

$Headers = New-GitHubHeaders -PatToken $PatToken

foreach ($Name in $RunnerNames) {
    try {
        $Removed = Remove-RunnerByName -Headers $Headers -RepoFullName $RepoFullName -RunnerName $Name
        if ($Removed) {
            Write-Host "🧹 Removed runner '$Name'." -ForegroundColor Yellow
        } else {
            Write-Host "ℹ️ Runner '$Name' not found in $RepoFullName." -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Failed to delete runner '$Name': $($_.Exception.Message)"
    }
}
