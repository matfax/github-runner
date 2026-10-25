#Requires -Version 7
<#
.SYNOPSIS
Starts a GitHub Actions runner container via the launch script

.DESCRIPTION
Loads the launch.ps1 script and starts a runner with the specified configuration.

.PARAMETER RegistrationToken
The registration token for the runner

.PARAMETER Platform
Target platform (linux or windows)

.PARAMETER Context
Build context (linux or windows)

.PARAMETER TestProject
Docker Compose project name for the test runner

.PARAMETER TestTag
Docker image tag to use for the test runner

.PARAMETER RunId
GitHub run ID for labeling

.EXAMPLE
.github/scripts/start-runner.ps1 -RegistrationToken "token" -Platform "linux" -Context "linux" -TestProject "test-123" -TestTag "runner-linux-local" -RunId "12345"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$RegistrationToken,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet("linux", "windows")]
    [string]$Platform,
    
    [Parameter(Mandatory = $true)]
    [string]$Context,
    
    [Parameter(Mandatory = $true)]
    [string]$TestProject,
    
    [Parameter(Mandatory = $true)]
    [string]$TestTag,
    
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    
    [Parameter()]
    [string]$RepoFullName = $env:GITHUB_REPOSITORY,
    
    [Parameter()]
    [int]$IdleTimeoutMinutes = [int]$env:RUNNER_IDLE_TIMEOUT_MINUTES,
    
    [Parameter()]
    [int]$MaxRestarts = [int]$env:RUNNER_MAX_RESTARTS
)

$ErrorActionPreference = 'Stop'

if (-not $RegistrationToken) { 
    throw "REG_TOKEN missing" 
}

. ./launch.ps1

$labels = "self-hosted,$Context,docker,run-$RunId"
$repoObj = [pscustomobject]@{ 
    full_name = $RepoFullName; 
    html_url = "https://github.com/$RepoFullName" 
}

$params = @{
    Repo = $repoObj
    RegToken = $RegistrationToken
    ComposeProject = $TestProject
    Platform = $Platform
    RunnerIdleTimeoutMinutes = $IdleTimeoutMinutes
    RunnerMaxRestarts = $MaxRestarts
    RunnerLabels = $labels
    RunnerImage = $TestTag
    RunnerName = $TestProject
    WithWsl = $false
}

Start-Runner @params
