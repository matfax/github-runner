# Helpers (moved from launch-common.ps1)
function Get-LaunchContext {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Repo,
        [string]$ComposeProject
    )

    $FullName = $Repo.full_name
    if (-not $FullName) { throw "Repo object must include full_name." }

    $Parts = $FullName.Trim('/').Split('/')
    if ($Parts.Count -eq 2) {
        $RepoUrl = $Repo.html_url
        if (-not $RepoUrl) { $RepoUrl = "https://github.com/$($Parts[0])/$($Parts[1])" }
        if (-not $ComposeProject) { $ComposeProject = "$($Parts[0])-$($Parts[1])" }
    }
    elseif ($Parts.Count -eq 1) {
        $RepoUrl = $Repo.html_url
        if (-not $RepoUrl) { $RepoUrl = "https://github.com/$($Parts[0])" }
        if (-not $ComposeProject) { $ComposeProject = $Parts[0] }
    }
    else {
        throw "RepoFullName must be 'owner/repo' or 'org'."
    }

    $ComposeProject = $ComposeProject -replace '[^A-Za-z0-9_-]', '-'
    return [pscustomobject]@{
        RepoUrl        = $RepoUrl
        ComposeProject = $ComposeProject
    }
}

function Invoke-RunnerCompose {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ComposePath,
        [Parameter(Mandatory = $true)]
        [string]$ComposeProject,
        [Parameter(Mandatory = $true)]
        [hashtable]$EnvVars,
        [Parameter(Mandatory = $true)]
        [bool]$UseWsl
    )

    if (-not (Test-Path $ComposePath)) {
        throw "Compose file not found at $ComposePath"
    }

    if ($UseWsl) {
        if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
            throw "WSL is not available."
        }
        $envArgs = @("env")
        foreach ($k in $EnvVars.Keys) { $envArgs += "$k=$($EnvVars[$k])" }
        wsl @($envArgs) docker compose -f $ComposePath -p $ComposeProject up -d --force-recreate --remove-orphans
        return $LASTEXITCODE
    } else {
        foreach ($k in $EnvVars.Keys) { Set-Item -Path "Env:$k" -Value $EnvVars[$k] }
        docker compose -f $ComposePath -p $ComposeProject up -d --force-recreate --remove-orphans
        $code = $LASTEXITCODE
        foreach ($k in $EnvVars.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
        return $code
    }
}

function Start-Runner {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Repo,
        [Parameter(Mandatory = $true)]
        [string]$RegToken,
        [string]$ComposeProject,
        [Parameter(Mandatory = $true)]
        [ValidateSet("windows", "linux")]
        [string]$Platform,
        [int]$RunnerIdleTimeoutMinutes = 15,
        [int]$RunnerMaxRestarts = 20,
        [string]$RunnerLabels = "",
        [string]$RunnerImage = "",
        [string]$RunnerName = "",
        [bool]$WithWsl = $false
    )

    $ErrorActionPreference = "Stop"

    if ([string]::IsNullOrWhiteSpace($RegToken)) {
        throw "Registration token was empty; cannot continue."
    }

    $Context = Get-LaunchContext -Repo $Repo -ComposeProject $ComposeProject
    $ComposeProject = $Context.ComposeProject
    $RepoUrl = $Context.RepoUrl
    if (-not $RunnerName) { $RunnerName = $ComposeProject }

    $ComposePath = Join-Path $PSScriptRoot "$Platform/docker-compose.yml"
    $UseWsl = ($Platform -eq "linux") -and $WithWsl

    $envVars = @{
        REPO_URL                    = $RepoUrl
        REG_TOKEN                   = $RegToken
        RUNNER_IDLE_TIMEOUT_MINUTES = $RunnerIdleTimeoutMinutes
        RUNNER_MAX_RESTARTS         = $RunnerMaxRestarts
        RUNNER_LABELS               = $RunnerLabels
    }
    if ($RunnerName) { $envVars["RUNNER_NAME"] = $RunnerName }
    if ($RunnerImage) { $envVars["RUNNER_IMAGE"] = $RunnerImage }

    Write-Host "🚀 Launching $Platform runner stack (project $ComposeProject)..." -ForegroundColor Green
    $code = Invoke-RunnerCompose -ComposePath $ComposePath -ComposeProject $ComposeProject -EnvVars $envVars -UseWsl:$UseWsl
    if ($code -ne 0) {
        throw "$Platform runner failed to start (exit code $code)."
    }
    Write-Host "✅ $Platform runner stack up (project $ComposeProject)." -ForegroundColor Gray
}
