param (
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.yml")
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/github-app.ps1"
. "$PSScriptRoot/kube-launch.ps1"
. "$PSScriptRoot/registration.ps1"
. "$PSScriptRoot/runner-api.ps1"

function Import-YamlConfig {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Config file not found at '$Path'. Copy config.example.yml to config.yml and fill in your values."
    }

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        try {
            Import-Module powershell-yaml -ErrorAction Stop | Out-Null
        } catch {
            throw "ConvertFrom-Yaml is not available. Install PowerShell 7+ or 'Install-Module powershell-yaml'."
        }
    }

    $Content = Get-Content -LiteralPath $Path -Raw
    try {
        return ConvertFrom-Yaml -Yaml $Content -ErrorAction Stop
    } catch {
        throw "Failed to parse YAML config at '$Path': $($_.Exception.Message)"
    }
}

function Coerce-Array {
    param ([object]$Value)
    if (-not $Value) { return @() }
    return @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-InstallationRepos {
    param (
        [hashtable]$Headers
    )

    $Repos = @()
    $Page = 1

    while ($true) {
        try {
            $Result = Invoke-RestMethod -Uri "https://api.github.com/installation/repositories?per_page=100&page=$Page" -Headers $Headers -ErrorAction Stop
        } catch {
            throw "Failed to list repos (page $Page): $($_.Exception.Message)"
        }
        if (-not $Result.repositories -or $Result.repositories.Count -eq 0) {
            break
        }

        $Repos += $Result.repositories

        if ($Result.repositories.Count -lt 100) {
            break
        }

        $Page++
    }

    return $Repos | Where-Object { -not $_.archived }
}

function Get-QueuedSelfHostedRun {
    param (
        [hashtable]$Headers,
        [string]$FullName,
        [string[]]$RequiredLabels,
        [regex]$OsLabelRegex
    )

    try {
        $Runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$FullName/actions/runs?status=queued&per_page=5" -Headers $Headers -ErrorAction Stop
    } catch {
        Write-Warning "Could not list runs for ${FullName}: $($_.Exception.Message)"
        return $null
    }

    foreach ($Run in $Runs.workflow_runs) {
        try {
            $Jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$FullName/actions/runs/$($Run.id)/jobs?filter=queued&per_page=20" -Headers $Headers -ErrorAction Stop
        } catch {
            Write-Warning "Could not list jobs for $FullName run $($Run.id): $($_.Exception.Message)"
            continue
        }

        foreach ($Job in $Jobs.jobs) {
            $labels = $Job.labels
            $hasRequired = $RequiredLabels | ForEach-Object { $labels -contains $_ } | Where-Object { $_ } | Select-Object -First 1
            $hasOs = $labels | Where-Object { $_ -match $OsLabelRegex } | Select-Object -First 1
            if ($hasRequired -and $hasOs) {
                return [pscustomobject]@{
                    RunId  = $Run.id
                    Labels = $labels
                }
            }
        }
    }

    return $null
}

function Get-RunnerProject {
    param (
        [string]$FullName
    )

    return ($FullName -replace '/', '-') -replace '[^A-Za-z0-9_-]', '-'
}

function Remove-StaleRunners {
    param (
        [hashtable]$Headers,
        [ref]$LaunchRegistry,
        [string]$Namespace,
        [int]$IdleTimeoutMinutes,
        [int]$CleanupGraceMinutes = 10
    )

    $Now = Get-Date
    $Keys = @($LaunchRegistry.Value.Keys)
    foreach ($Key in $Keys) {
        $Entry = $LaunchRegistry.Value[$Key]
        if (-not $Entry) { continue }

        $Project = $Key
        if (Test-KubeRunnerActive -Namespace $Namespace -Project $Project) { continue }

        $AgeMinutes = ($Now - $Entry.LaunchedAt).TotalMinutes
        if ($AgeMinutes -lt ($IdleTimeoutMinutes + $CleanupGraceMinutes)) { continue }

        $Removed = $false
        try {
            $Removed = Remove-RunnerByName -Headers $Headers -RepoFullName $Entry.RepoFullName -RunnerName $Entry.RunnerName
        } catch {
            Write-Warning "Failed to delete stale runner '$($Entry.RunnerName)' from $($Entry.RepoFullName): $($_.Exception.Message)"
        }

        if (-not $Removed) {
            Write-Host "ℹ️ Runner '$($Entry.RunnerName)' not found in $($Entry.RepoFullName); removing from registry." -ForegroundColor Gray
            $null = $LaunchRegistry.Value.Remove($Key)
            continue
        }

        Write-Host "🧹 Removed stale runner '$($Entry.RunnerName)' (project $Project)." -ForegroundColor Yellow
        $null = $LaunchRegistry.Value.Remove($Key)
    }
}

function Get-RunnerNamespace {
    param ([string]$Configured)

    if ($Configured) { return $Configured }
    if ($env:RUNNER_NAMESPACE) { return $env:RUNNER_NAMESPACE }

    $ServiceAccountNamespace = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
    if (Test-Path -LiteralPath $ServiceAccountNamespace) {
        return (Get-Content -LiteralPath $ServiceAccountNamespace -Raw).Trim()
    }

    throw "Runner namespace unknown. Set 'namespace' in the config or RUNNER_NAMESPACE."
}

$Config = Import-YamlConfig -Path $ConfigPath

$Owner = $Config.owner
$IncludeRepos = Coerce-Array -Value $Config.includeRepos
$ExcludeRepos = Coerce-Array -Value $Config.excludeRepos
$PollSeconds = if ($Config.pollSeconds) { [int]$Config.pollSeconds } else { 30 }
$MaxLaunchPerCycle = if ($Config.maxLaunchPerCycle) { [int]$Config.maxLaunchPerCycle } else { 2 }
$RequiredLabels = if ($Config.requiredLabels) { Coerce-Array -Value $Config.requiredLabels } else { @("self-hosted") }
$WindowsLabelRegex = if ($Config.windowsLabelRegex) { [regex]$Config.windowsLabelRegex } else { [regex]"(?i)windows" }
$LinuxLabelRegex = if ($Config.linuxLabelRegex) { [regex]$Config.linuxLabelRegex } else { [regex]"(?i)linux" }
$RunnerIdleTimeoutMinutes = if ($Config.runnerIdleTimeoutMinutes) { [int]$Config.runnerIdleTimeoutMinutes } else { 15 }
$RunnerMaxRestarts = if ($Config.runnerMaxRestarts) { [int]$Config.runnerMaxRestarts } else { 20 }
$RunnerTemplates = if ($Config.runnerTemplates) { $Config.runnerTemplates } else { @{} }
$Namespace = Get-RunnerNamespace -Configured $Config.namespace
$RunnerCleanupGraceMinutes = 10
$HeartbeatPath = Join-Path ([IO.Path]::GetTempPath()) "watcher-heartbeat"

$GitHubAppId = $env:GITHUB_APP_ID
$GitHubAppInstallationId = $env:GITHUB_APP_INSTALLATION_ID
$GitHubAppPrivateKeyPath = $env:GITHUB_APP_PRIVATE_KEY_PATH

if ([string]::IsNullOrWhiteSpace($GitHubAppId) -or [string]::IsNullOrWhiteSpace($GitHubAppPrivateKeyPath)) {
    throw "GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY_PATH must be set (GITHUB_APP_INSTALLATION_ID is optional)."
}

$Platforms = @(
    @{
        Name          = "windows"
        Suffix        = "-win"
        OsRegex       = $WindowsLabelRegex
        Template      = $RunnerTemplates.windows
        LaunchMessage = "🚀 Queued Windows self-hosted job detected for {0}. Launching runner..."
    },
    @{
        Name          = "linux"
        Suffix        = "-linux"
        OsRegex       = $LinuxLabelRegex
        Template      = $RunnerTemplates.linux
        LaunchMessage = "🐧 Queued Linux self-hosted job detected for {0}. Launching runner..."
    }
) | Where-Object { $_.Template }

if (-not $Platforms) {
    throw "No runner templates configured (runnerTemplates.linux / runnerTemplates.windows in $ConfigPath)."
}

$SeenRunIds = @{}
$LaunchRegistry = @{}

Write-Host "👀 Watching for queued self-hosted jobs ($(($Platforms | ForEach-Object { $_.Name }) -join ', ')) in namespace $Namespace..." -ForegroundColor Cyan

while ($true) {
    $Launched = 0
    $Token = $null
    $Headers = $null
    Set-Content -LiteralPath $HeartbeatPath -Value (Get-Date -Format o)

    try {
        $Token = Get-GitHubAppToken -AppId $GitHubAppId -PrivateKeyPath $GitHubAppPrivateKeyPath -InstallationId $GitHubAppInstallationId -Owner $Owner
        $Headers = New-GitHubHeaders -Token $Token
    } catch {
        Write-Warning "Failed to obtain GitHub App installation token: $($_.Exception.Message)"
        Start-Sleep -Seconds $PollSeconds
        continue
    }

    try {
        $Repos = Get-InstallationRepos -Headers $Headers
    } catch {
        Write-Warning "Failed to list repositories: $($_.Exception.Message)"
        Start-Sleep -Seconds $PollSeconds
        continue
    }

    if ($IncludeRepos.Count -gt 0) {
        $Repos = $Repos | Where-Object { $IncludeRepos -contains $_.full_name }
    }

    if ($Owner) {
        $Repos = $Repos | Where-Object { $_.owner.login -ieq $Owner }
    }

    if ($ExcludeRepos.Count -gt 0) {
        $Repos = $Repos | Where-Object { $ExcludeRepos -notcontains $_.full_name }
    }

    foreach ($Repo in $Repos) {
        if ($Launched -ge $MaxLaunchPerCycle) {
            break
        }

        $BaseProject = Get-RunnerProject -FullName $Repo.full_name
        $RegTokenForRepo = $null

        foreach ($Platform in $Platforms) {
            if ($Launched -ge $MaxLaunchPerCycle) { break }

            $Project = "$BaseProject$($Platform.Suffix)"
            try {
                if (Test-KubeRunnerActive -Namespace $Namespace -Project $Project) { continue }
            } catch {
                Write-Warning "Could not check runner Jobs for ${Project}: $($_.Exception.Message)"
                continue
            }

            $Queued = Get-QueuedSelfHostedRun -Headers $Headers -FullName $Repo.full_name -RequiredLabels $RequiredLabels -OsLabelRegex $Platform.OsRegex
            if (-not $Queued -or $SeenRunIds.ContainsKey($Queued.RunId)) { continue }

            Write-Host ($Platform.LaunchMessage -f $Repo.full_name) -ForegroundColor Green
            $SeenRunIds[$Queued.RunId] = Get-Date
            $Labels = ($Queued.Labels -join ',')
            $RunnerName = $Project

            if (-not $RegTokenForRepo) {
                try {
                    $RegTokenForRepo = New-RegistrationToken -Token $Token -RepoFullName $Repo.full_name
                } catch {
                    Write-Warning "Failed to create registration token for $($Repo.full_name): $($_.Exception.Message)"
                    continue
                }
            }

            try {
                Start-KubeRunner -Repo $Repo -RegToken $RegTokenForRepo -Project $Project -Platform $Platform.Name -TemplatePath $Platform.Template -Namespace $Namespace -RunnerIdleTimeoutMinutes $RunnerIdleTimeoutMinutes -RunnerMaxRestarts $RunnerMaxRestarts -RunnerLabels $Labels -RunnerName $RunnerName
            } catch {
                Write-Warning "Failed to launch $($Platform.Name) runner for $($Repo.full_name): $($_.Exception.Message)"
                continue
            }
            $LaunchRegistry[$Project] = [pscustomobject]@{
                RepoFullName = $Repo.full_name
                RunnerName   = $RunnerName
                Platform     = $Platform.Name
                LaunchedAt   = Get-Date
            }
            $Launched++
        }
    }

    try {
        Remove-StaleRunners -Headers $Headers -LaunchRegistry ([ref]$LaunchRegistry) -Namespace $Namespace -IdleTimeoutMinutes $RunnerIdleTimeoutMinutes -CleanupGraceMinutes $RunnerCleanupGraceMinutes
    } catch {
        Write-Warning "Failed stale-runner cleanup: $($_.Exception.Message)"
    }
    $Token = $null
    $Headers = $null
    Start-Sleep -Seconds $PollSeconds
}
