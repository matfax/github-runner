#Requires -Version 7
<#
.SYNOPSIS
Waits for runner container to log "Listening for jobs" indicating readiness

.DESCRIPTION
Polls container logs until the readiness message appears or timeout expires.

.PARAMETER ProjectName
The Docker Compose project name to identify the container

.PARAMETER TimeoutMinutes
Maximum minutes to wait for readiness (default: 2)

.EXAMPLE
wait-runner-ready.ps1 -ProjectName "test-1234-linux" -TimeoutMinutes 2
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

$containerId = Get-ContainerId -Project $ProjectName
if (-not $containerId) { 
    throw "No container found for project '$ProjectName'." 
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$ready = $false

while ((Get-Date) -lt $deadline) {
    $logs = docker logs $containerId 2>$null
    if ($logs -match "Listening for Jobs") {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 5
}

Write-Host "===== runner logs ($containerId) ====="
docker logs $containerId
Write-Host "======================================"

if (-not $ready) {
    throw "Runner container '$containerId' did not log readiness ('Listening for Jobs')."
}
