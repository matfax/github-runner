#Requires -Version 7
<#
.SYNOPSIS
Ensures a Docker runner container reaches running state within timeout period

.DESCRIPTION
Polls container status until it reaches running state or timeout expires.
Checks both docker compose project labels and container state.

.PARAMETER ProjectName
The Docker Compose project name to identify the container

.PARAMETER TimeoutMinutes
Maximum minutes to wait for container to start (default: 2)

.EXAMPLE
ensure-runner-running.ps1 -ProjectName "test-1234-linux" -TimeoutMinutes 2
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    
    [Parameter()]
    [int]$TimeoutMinutes = 2
)

$ErrorActionPreference = 'Stop'

function Get-ContainerId {
    param([string]$Project)
    $id = docker ps --filter "label=com.docker.compose.project=$Project" --format "{{.ID}}" | Select-Object -First 1
    if (-not $id) {
        $id = docker ps -a --filter "label=com.docker.compose.project=$Project" --format "{{.ID}}" | Select-Object -First 1
    }
    return $id
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$state = $null
$containerId = $null

while ((Get-Date) -lt $deadline) {
    $containerId = Get-ContainerId -Project $ProjectName
    if (-not $containerId) {
        Start-Sleep -Seconds 5
        continue
    }

    $stateJson = docker inspect --format "{{json .State}}" $containerId 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $stateJson) {
        Start-Sleep -Seconds 5
        continue
    }
    
    $state = $stateJson | ConvertFrom-Json
    if ($state.Running) {
        Write-Host "✅ Runner container '$containerId' is running."
        break
    }
    
    if ($state.Status -eq "exited") {
        Write-Host "ℹ️ Container exited early. State: $(ConvertTo-Json $state -Compress)"
        docker logs $containerId
        throw "Runner container exited with code $($state.ExitCode)."
    }
    
    Start-Sleep -Seconds 5
}

if (-not $state -or -not $state.Running) {
    if ($state) { 
        Write-Host "ℹ️ Final container state: $(ConvertTo-Json $state -Compress)" 
    }
    if ($containerId) { 
        docker logs $containerId 
    }
    throw "Runner container for project '$ProjectName' did not reach running state before timeout."
}
