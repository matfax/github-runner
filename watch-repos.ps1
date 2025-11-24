param (
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.yml")
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/launch.ps1"
. "$PSScriptRoot/registration.ps1"

function Parse-OpSecretRef {
    param ([string]$SecretRef)

    if ([string]::IsNullOrWhiteSpace($SecretRef)) {
        throw "connectSecretRef is required (format: op://Vault/Item/Field)."
    }

    if ($SecretRef -notmatch '^op:\/\/([^\/]+)\/([^\/]+)\/(.+)$') {
        throw "connectSecretRef must be in format op://Vault/Item/Field (got '$SecretRef')."
    }

    return @{
        Vault = $Matches[1]
        Item  = $Matches[2]
        Field = $Matches[3]
    }
}

function Ensure-ConnectServer {
    $ConnectDir = Join-Path $PSScriptRoot "connect"
    $ComposePath = Join-Path $ConnectDir "docker-compose.yml"
    $CredsPath = Join-Path $ConnectDir "1password-credentials.json"

    if (-not (Test-Path $ComposePath)) {
        throw "1Password Connect compose file not found at $ComposePath"
    }

    if (-not (Test-Path $CredsPath)) {
        throw "1Password Connect credentials file missing at $CredsPath. Follow https://developer.1password.com/docs/connect/get-started/ to create it."
    }

    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        throw "WSL is required to start the 1Password Connect stack (Linux container). Install/enable WSL."
    }

    Write-Host "🔗 Ensuring 1Password Connect is running in WSL..." -ForegroundColor Cyan
    Push-Location $ConnectDir
    try {
        wsl docker compose up -d
        $ExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($ExitCode -ne 0) {
        throw "Failed to start 1Password Connect via WSL (exit code $ExitCode)."
    } else {
        Write-Host "   1Password Connect stack is up." -ForegroundColor Gray
    }
}

function Ensure-CacheServer {
    $CacheDir = Join-Path $PSScriptRoot "caching"
    $ComposePath = Join-Path $CacheDir "docker-compose.yml"

    if (-not (Test-Path $ComposePath)) {
        Write-Warning "Cache compose file not found at $ComposePath"
        return
    }

    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Write-Warning "WSL is not available. Skipping cache server startup."
        return
    }

    Write-Host "💾 Ensuring cache server is running in WSL..." -ForegroundColor Cyan
    Push-Location $CacheDir
    try {
        wsl docker compose up -d
        $ExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($ExitCode -ne 0) {
        Write-Warning "Failed to start cache server via WSL (exit code $ExitCode)."
    } else {
        Write-Host "   Cache server stack is up (shared for all projects)." -ForegroundColor Gray
    }
}

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

function New-GitHubHeaders {
    param (
        [string]$PatToken
    )

    return @{
        "Authorization"        = "Bearer $PatToken"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "gh-runner-auto-launch"
    }
}

function Get-AdminRepos {
    param (
        [hashtable]$Headers
    )

    $Repos = @()
    $Page = 1

    while ($true) {
        try {
            $Result = Invoke-RestMethod -Uri "https://api.github.com/user/repos?per_page=100&page=$Page" -Headers $Headers -ErrorAction Stop
        } catch {
            throw "Failed to list repos (page $Page): $($_.Exception.Message)"
        }
        if (-not $Result -or $Result.Count -eq 0) {
            break
        }

        $Repos += $Result

        if ($Result.Count -lt 100) {
            break
        }

        $Page++
    }

    return $Repos | Where-Object { $_.permissions.admin -eq $true }
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
        Write-Warning "Could not list runs for $FullName: $($_.Exception.Message)"
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

function Get-ComposeProject {
    param (
        [string]$FullName
    )

    return ($FullName -replace '/', '-') -replace '[^A-Za-z0-9_-]', '-'
}

function HasActiveRunner {
    param (
        [string]$ComposeProject
    )

    $Containers = docker ps --filter "label=com.docker.compose.project=$ComposeProject" -q
    return -not [string]::IsNullOrWhiteSpace(($Containers | Select-Object -First 1))
}

function HasActiveRunnerLinux {
    param (
        [string]$ComposeProject
    )

    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Write-Warning "WSL is not available; cannot check Linux runner state."
        return $false
    }

    $Containers = wsl docker ps --filter "label=com.docker.compose.project=$ComposeProject" -q
    return -not [string]::IsNullOrWhiteSpace(($Containers | Select-Object -First 1))
}

function Resolve-ConnectIds {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConnectUrl,
        [Parameter(Mandatory = $true)]
        [string]$ConnectToken,
        [Parameter(Mandatory = $true)]
        [string]$VaultName,
        [Parameter(Mandatory = $true)]
        [string]$ItemName
    )

    $Headers = @{ "Authorization" = "Bearer $ConnectToken" }

    try {
        $Vaults = Invoke-RestMethod -Uri "$ConnectUrl/v1/vaults" -Headers $Headers -Method Get -ErrorAction Stop
    } catch {
        throw "Failed to list vaults from 1Password Connect: $($_.Exception.Message)"
    }

    $Vault = $Vaults | Where-Object { $_.name -eq $VaultName } | Select-Object -First 1
    if (-not $Vault) {
        throw "Vault '$VaultName' not found in Connect."
    }

    try {
        $Items = Invoke-RestMethod -Uri "$ConnectUrl/v1/vaults/$($Vault.id)/items" -Headers $Headers -Method Get -ErrorAction Stop
    } catch {
        throw "Failed to list items for vault '$VaultName': $($_.Exception.Message)"
    }

    $Item = $Items | Where-Object { $_.title -eq $ItemName } | Select-Object -First 1
    if (-not $Item) {
        throw "Item '$ItemName' not found in vault '$VaultName'."
    }

    return @{
        VaultId = $Vault.id
        ItemId  = $Item.id
    }
}

function Get-PatFromConnect {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConnectUrl,
        [Parameter(Mandatory = $true)]
        [string]$ConnectToken,
        [Parameter(Mandatory = $true)]
        [string]$SecretRef
    )

    $Parsed = Parse-OpSecretRef -SecretRef $SecretRef
    $Resolution = Resolve-ConnectIds -ConnectUrl $ConnectUrl -ConnectToken $ConnectToken -VaultName $Parsed.Vault -ItemName $Parsed.Item

    $Headers = @{ "Authorization" = "Bearer $ConnectToken" }

    $Uri = "$ConnectUrl/v1/vaults/$($Resolution.VaultId)/items/$($Resolution.ItemId)"
    try {
        $Item = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
    } catch {
        throw "Failed to fetch PAT item from 1Password Connect: $($_.Exception.Message)"
    }

    $FieldName = $Parsed.Field
    $Field = $Item.fields | Where-Object { $_.label -eq $FieldName -or $_.purpose -eq "PASSWORD" } | Select-Object -First 1
    if (-not $Field -or [string]::IsNullOrWhiteSpace($Field.value)) {
        throw "Field '$FieldName' was not found or was empty in the Connect item."
    }

    return $Field.value
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
$ConnectUrl = $Config.connectUrl
$ConnectToken = $Config.connectToken
$ConnectSecretRef = $Config.connectSecretRef

if ([string]::IsNullOrWhiteSpace($ConnectUrl) -or
    [string]::IsNullOrWhiteSpace($ConnectToken) -or
    [string]::IsNullOrWhiteSpace($ConnectSecretRef)) {
    throw "connectUrl, connectToken, and connectSecretRef must be set in $ConfigPath for 1Password Connect."
}

$SeenRunIds = @{}

Write-Host "👀 Watching for queued self-hosted jobs across repos you administer..." -ForegroundColor Cyan

Ensure-ConnectServer
Ensure-CacheServer

while ($true) {
    $Launched = 0
    $PatToken = $null
    $Headers = $null

    try {
        $PatToken = Get-PatFromConnect -ConnectUrl $ConnectUrl -ConnectToken $ConnectToken -SecretRef $ConnectSecretRef
        $Headers = New-GitHubHeaders -PatToken $PatToken
    } catch {
        Write-Warning "Failed to retrieve PAT from 1Password Connect: $($_.Exception.Message)"
        Start-Sleep -Seconds $PollSeconds
        continue
    }

    try {
        $Repos = Get-AdminRepos -Headers $Headers
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

        $BaseComposeProject = Get-ComposeProject -FullName $Repo.full_name
        $RegTokenForRepo = $null

        $Platforms = @(
            @{
                Name           = "windows"
                Suffix         = "-win"
                OsRegex        = $WindowsLabelRegex
                WithWsl        = $false
                ActiveCheck    = { param($Project) HasActiveRunner -ComposeProject $Project }
                LaunchMessage  = "🚀 Queued Windows self-hosted job detected for $($Repo.full_name). Launching runner..."
            },
            @{
                Name           = "linux"
                Suffix         = "-linux"
                OsRegex        = $LinuxLabelRegex
                WithWsl        = $true
                ActiveCheck    = { param($Project) HasActiveRunnerLinux -ComposeProject $Project }
                LaunchMessage  = "🐧 Queued Linux self-hosted job detected for $($Repo.full_name). Launching runner..."
            }
        )

        foreach ($Platform in $Platforms) {
            if ($Launched -ge $MaxLaunchPerCycle) { break }

            $ComposeProject = "$BaseComposeProject$($Platform.Suffix)"
            $IsActive = & $Platform.ActiveCheck $ComposeProject
            if ($IsActive) { continue }

            $Queued = Get-QueuedSelfHostedRun -Headers $Headers -FullName $Repo.full_name -RequiredLabels $RequiredLabels -OsLabelRegex $Platform.OsRegex
            if (-not $Queued -or $SeenRunIds.ContainsKey($Queued.RunId)) { continue }

            Write-Host $Platform.LaunchMessage -ForegroundColor Green
            $SeenRunIds[$Queued.RunId] = Get-Date
            $Labels = ($Queued.Labels -join ',')

            if (-not $RegTokenForRepo) {
                try {
                    $RegTokenForRepo = New-RegistrationToken -PatToken $PatToken -RepoFullName $Repo.full_name
                } catch {
                    Write-Warning "Failed to create registration token for $($Repo.full_name): $($_.Exception.Message)"
                    continue
                }
            }

            Start-Runner -Repo $Repo -RegToken $RegTokenForRepo -PatToken $PatToken -ComposeProject $ComposeProject -Platform $Platform.Name -RunnerIdleTimeoutMinutes $RunnerIdleTimeoutMinutes -RunnerMaxRestarts $RunnerMaxRestarts -RunnerLabels $Labels -WithWsl:$($Platform.WithWsl)
            $Launched++
        }
    }

    $PatToken = $null
    $Headers = $null
    Start-Sleep -Seconds $PollSeconds
}
